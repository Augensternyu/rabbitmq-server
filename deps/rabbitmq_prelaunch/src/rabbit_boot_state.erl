%%%-------------------------------------------------------------------
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2025 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

-module(rabbit_boot_state).

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

-include_lib("rabbit_common/include/logging.hrl").

-export([get/0,
         set/1,
         wait_for/2,
         has_reached/1,
         has_reached_and_is_active/1,
         get_start_time/0,
         record_start_time/0]).

-define(PT_KEY_BOOT_STATE, {?MODULE, boot_state}).
-define(PT_KEY_START_TIME, {?MODULE, start_time}).

-type boot_state() :: stopped |
                      booting |
                      core_started |
                      ready |
                      stopping.

-export_type([boot_state/0]).

-spec get() -> boot_state().
get() ->
    persistent_term:get(?PT_KEY_BOOT_STATE, stopped).

-spec set(boot_state()) -> ok.
set(BootState) ->
    ?LOG_DEBUG("Change boot state to `~ts`", [BootState],
               #{domain => ?RMQLOG_DOMAIN_PRELAUNCH}),
    ?assert(is_valid(BootState)),
    case BootState of
        stopped -> persistent_term:erase(?PT_KEY_BOOT_STATE);
        _       -> persistent_term:put(?PT_KEY_BOOT_STATE, BootState)
    end,
    rabbit_boot_state_sup:notify_boot_state_listeners(BootState).

-spec wait_for(boot_state(), timeout()) -> ok | {error, timeout}.
wait_for(BootState, infinity) ->
    case has_reached(BootState) of
        true  -> ok;
        false -> Wait = 200,
                 timer:sleep(Wait),
                 wait_for(BootState, infinity)
    end;
wait_for(BootState, Timeout)
  when is_integer(Timeout) andalso Timeout >= 0 ->
    case has_reached(BootState) of
        true  -> ok;
        false -> Wait = 200,
                 timer:sleep(Wait),
                 wait_for(BootState, Timeout - Wait)
    end;
wait_for(_, _) ->
    {error, timeout}.

boot_state_idx(stopped)      -> 0;
boot_state_idx(booting)      -> 1;
boot_state_idx(core_started) -> 2;
boot_state_idx(ready)        -> 3;
boot_state_idx(stopping)     -> 4.

is_valid(BootState) ->
    is_integer(boot_state_idx(BootState)).

has_reached(TargetBootState) ->
    has_reached(?MODULE:get(), TargetBootState).

has_reached(CurrentBootState, CurrentBootState) ->
    true;
has_reached(stopping, stopped) ->
    false;
has_reached(_CurrentBootState, stopped) ->
    true;
has_reached(stopped, _TargetBootState) ->
    true;
has_reached(CurrentBootState, TargetBootState) ->
    boot_state_idx(TargetBootState) =< boot_state_idx(CurrentBootState).

has_reached_and_is_active(TargetBootState) ->
    case ?MODULE:get() of
        stopped ->
            false;
        CurrentBootState ->
            has_reached(CurrentBootState, TargetBootState)
            andalso
            not has_reached(CurrentBootState, stopping)
    end.

-spec get_start_time() -> StartTime when
      StartTime :: integer().
%% @doc Returns the start time of the Erlang VM.
%%
%% This time was recorded by {@link record_start_time/0} as early as possible
%% and is immutable.

get_start_time() ->
    persistent_term:get(?PT_KEY_START_TIME).

-spec record_start_time() -> ok.
%% @doc Records the start time of the Erlang VM.
%%
%% The time is expressed in microseconds since Epoch. It can be compared to
%% other non-native times. This is used by the Peer Discovery subsystem to
%% sort nodes and select a seed node if the peer discovery backend did not
%% select one.
%%
%% This time is recorded once. Calling this function multiple times won't
%% overwrite the value.

record_start_time() ->
    Key = ?PT_KEY_START_TIME,
    try
        %% Check if the start time was recorded.
        _ = persistent_term:get(Key),
        ok
    catch
        error:badarg ->
            %% The start time was not recorded yet. Acquire a lock and check
            %% again in case another process got the lock first and recorded
            %% the start time.
            Node = node(),
            LockId = {?PT_KEY_START_TIME, self()},
            true = global:set_lock(LockId, [Node]),
            try
                _ = persistent_term:get(Key),
                ok
            catch
                error:badarg ->
                    %% We are really the first to get the lock and we can
                    %% record the start time.
                    NativeStartTime = erlang:system_info(start_time),
                    TimeOffset = erlang:time_offset(),
                    SystemStartTime = NativeStartTime + TimeOffset,
                    StartTime = erlang:convert_time_unit(
                                  SystemStartTime, native, microsecond),
                    persistent_term:put(Key, StartTime)
            after
                global:del_lock(LockId, [Node])
            end
    end.
