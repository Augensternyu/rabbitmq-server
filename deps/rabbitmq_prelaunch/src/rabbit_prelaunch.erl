-module(rabbit_prelaunch).

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

-include_lib("rabbit_common/include/logging.hrl").

-export([run_prelaunch_first_phase/0,
         assert_mnesia_is_stopped/0,
         get_context/0,
         get_stop_reason/0,
         set_stop_reason/1,
         clear_stop_reason/0,
         is_initial_pass/0,
         initial_pass_finished/0,
         shutdown_func/1]).

-ifdef(TEST).
-export([store_context/1,
         clear_context_cache/0]).
-endif.

-define(PT_KEY_CONTEXT,       {?MODULE, context}).
-define(PT_KEY_INITIAL_PASS,  {?MODULE, initial_pass_finished}).
-define(PT_KEY_SHUTDOWN_FUNC, {?MODULE, chained_shutdown_func}).
-define(PT_KEY_STOP_REASON,   {?MODULE, stop_reason}).

run_prelaunch_first_phase() ->
    try
        ok = logger:set_process_metadata(
               #{domain => ?RMQLOG_DOMAIN_PRELAUNCH}),
        do_run()
    catch
        throw:{error, _} = Error ->
            rabbit_prelaunch_errors:log_error(Error),
            set_stop_reason(Error),
            rabbit_boot_state:set(stopped),
            Error;
        Class:Exception:Stacktrace ->
            rabbit_prelaunch_errors:log_exception(
              Class, Exception, Stacktrace),
            Error = {error, Exception},
            set_stop_reason(Error),
            rabbit_boot_state:set(stopped),
            Error
    end.

do_run() ->
    %% Indicate RabbitMQ is booting.
    clear_stop_reason(),
    rabbit_boot_state:record_start_time(),
    rabbit_boot_state:set(booting),

    %% Configure dbg if requested.
    rabbit_prelaunch_early_logging:enable_quick_dbg(rabbit_env:dbg_config()),

    %% Setup signal handler.
    ok = rabbit_prelaunch_sighandler:setup(),

    %% We assert Mnesia is stopped before we run the prelaunch
    %% phases.
    %%
    %% We need this because our cluster consistency check (in the second
    %% phase) depends on Mnesia not being started before it has a chance
    %% to run.
    %%
    %% Also, in the initial pass, we don't want Mnesia to run before
    %% Erlang distribution is configured.
    assert_mnesia_is_stopped(),

    %% Get informations to setup logging.
    Context0 = rabbit_env:get_context_before_logging_init(),
    ?assertMatch(#{}, Context0),

    %% Setup logging for the prelaunch phase.
    ok = rabbit_prelaunch_early_logging:setup_early_logging(Context0),

    IsInitialPass = is_initial_pass(),
    case IsInitialPass of
        true ->
            ?LOG_DEBUG(""),
            ?LOG_DEBUG("== Prelaunch phase [1/2] (initial pass) =="),
            ?LOG_DEBUG("");
        false ->
            ?LOG_DEBUG(""),
            ?LOG_DEBUG("== Prelaunch phase [1/2] =="),
            ?LOG_DEBUG("")
    end,
    rabbit_env:log_process_env(),

    %% Load rabbitmq-env.conf, redo logging setup and continue.
    Context1 = rabbit_env:get_context_after_logging_init(Context0),
    ?assertMatch(#{}, Context1),
    ok = rabbit_prelaunch_early_logging:setup_early_logging(Context1),
    rabbit_env:log_process_env(),

    %% Complete context now that we have the final environment loaded.
    Context2 = rabbit_env:get_context_after_reloading_env(Context1),
    ?assertMatch(#{}, Context2),
    store_context(Context2),
    rabbit_env:log_context(Context2),
    ok = setup_shutdown_func(),

    Context = Context2#{initial_pass => IsInitialPass},

    rabbit_env:context_to_code_path(Context),
    rabbit_env:context_to_app_env_vars(Context),

    %% 1. Erlang/OTP compatibility check.
    ok = rabbit_prelaunch_erlang_compat:check(Context),

    %% 2. Configuration check + loading.
    ok = rabbit_prelaunch_conf:setup(Context),

    %% 3. Erlang distribution check + start.
    ok = rabbit_prelaunch_dist:setup(Context),

    %% 4. Write PID file.
    ?LOG_DEBUG(""),
    _ = write_pid_file(Context),

    %% Garbage collect before returning because we do not want
    %% to keep memory around forever unnecessarily, even if just
    %% a few MiBs, because it will pollute output from tools like
    %% Observer or observer_cli.
    _ = erlang:garbage_collect(),

    ignore.

assert_mnesia_is_stopped() ->
    ?assertNot(lists:keymember(mnesia, 1, application:which_applications())).

store_context(Context) when is_map(Context) ->
    persistent_term:put(?PT_KEY_CONTEXT, Context).

get_context() ->
    case persistent_term:get(?PT_KEY_CONTEXT, undefined) of
        undefined -> undefined;
        Context   -> Context#{initial_pass => is_initial_pass()}
    end.

-ifdef(TEST).
clear_context_cache() ->
    persistent_term:erase(?PT_KEY_CONTEXT).
-endif.

get_stop_reason() ->
    persistent_term:get(?PT_KEY_STOP_REASON, undefined).

set_stop_reason(Reason) ->
    case get_stop_reason() of
        undefined ->
            ?LOG_DEBUG("Set stop reason to: ~tp", [Reason]),
            persistent_term:put(?PT_KEY_STOP_REASON, Reason);
        _ ->
            ok
    end.

clear_stop_reason() ->
    persistent_term:erase(?PT_KEY_STOP_REASON).

is_initial_pass() ->
    not persistent_term:get(?PT_KEY_INITIAL_PASS, false).

initial_pass_finished() ->
    persistent_term:put(?PT_KEY_INITIAL_PASS, true).

setup_shutdown_func() ->
    ThisMod = ?MODULE,
    ThisFunc = shutdown_func,
    ExistingShutdownFunc = application:get_env(kernel, shutdown_func),
    case ExistingShutdownFunc of
        {ok, {ThisMod, ThisFunc}} ->
            ok;
        {ok, {ExistingMod, ExistingFunc}} ->
            ?LOG_DEBUG(
              "Setting up kernel shutdown function: ~ts:~ts/1 "
              "(chained with ~ts:~ts/1)",
              [ThisMod, ThisFunc, ExistingMod, ExistingFunc]),
            ok = persistent_term:put(
                   ?PT_KEY_SHUTDOWN_FUNC,
                   ExistingShutdownFunc),
            ok = record_kernel_shutdown_func(ThisMod, ThisFunc);
        _ ->
            ?LOG_DEBUG(
              "Setting up kernel shutdown function: ~ts:~ts/1",
              [ThisMod, ThisFunc]),
            ok = record_kernel_shutdown_func(ThisMod, ThisFunc)
    end.

record_kernel_shutdown_func(Mod, Func) ->
    application:set_env(
      kernel, shutdown_func, {Mod, Func},
      [{persistent, true}]).

shutdown_func(Reason) ->
    ?LOG_DEBUG(
      "Running ~ts:shutdown_func() as part of `kernel` shutdown", [?MODULE]),
    Context = get_context(),
    remove_pid_file(Context),
    ChainedShutdownFunc = persistent_term:get(
                            ?PT_KEY_SHUTDOWN_FUNC,
                            undefined),
    case ChainedShutdownFunc of
        {ChainedMod, ChainedFunc} -> ChainedMod:ChainedFunc(Reason);
        _                         -> ok
    end.

write_pid_file(#{pid_file := PidFile}) ->
    ?LOG_DEBUG("Writing PID file: ~ts", [PidFile]),
    case filelib:ensure_dir(PidFile) of
        ok ->
            OSPid = os:getpid(),
            case file:write_file(PidFile, OSPid) of
                ok ->
                    ok;
                {error, Reason} = Error ->
                    ?LOG_WARNING(
                      "Failed to write PID file \"~ts\": ~ts",
                      [PidFile, file:format_error(Reason)]),
                    Error
            end;
        {error, Reason} = Error ->
            ?LOG_WARNING(
              "Failed to create PID file \"~ts\" directory: ~ts",
              [PidFile, file:format_error(Reason)]),
            Error
    end;
write_pid_file(_) ->
    ok.

remove_pid_file(#{pid_file := PidFile, keep_pid_file_on_exit := true}) ->
    ?LOG_DEBUG("Keeping PID file: ~ts", [PidFile]),
    ok;
remove_pid_file(#{pid_file := PidFile}) ->
    ?LOG_DEBUG("Deleting PID file: ~ts", [PidFile]),
    _ = file:delete(PidFile),
    ok;
remove_pid_file(_) ->
    ok.
