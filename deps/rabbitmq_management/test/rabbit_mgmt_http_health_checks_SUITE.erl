%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2025 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

-module(rabbit_mgmt_http_health_checks_SUITE).

-include("rabbit_mgmt.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("rabbitmq_ct_helpers/include/rabbit_mgmt_test.hrl").

-import(rabbit_mgmt_test_util, [http_get/3,
                                req/4,
                                auth_header/2]).

-define(PATH_PREFIX, "/custom-prefix").

-compile(nowarn_export_all).
-compile(export_all).

all() ->
    [
     {group, cluster_size_3},
     {group, cluster_size_5},
     {group, single_node}
    ].

groups() ->
    [
     {cluster_size_3, [], all_tests()},
     {cluster_size_5, [], [is_quorum_critical_test]},
     {single_node, [], [
                        alarms_test,
                        local_alarms_test,
                        metadata_store_initialized_test,
                        metadata_store_initialized_with_data_test,
                        is_quorum_critical_single_node_test,
                        quorum_queues_without_elected_leader_single_node_test,
                        quorum_queues_without_elected_leader_across_all_virtual_hosts_single_node_test
     ]}
    ].

all_tests() -> [
                health_checks_test,
                virtual_hosts_test,
                metadata_store_initialized_test,
                metadata_store_initialized_with_data_test,
                protocol_listener_test,
                port_listener_test,
                certificate_expiration_test,
                is_in_service_test,
                below_node_connection_limit_test,
                ready_to_serve_clients_test
               ].

%% -------------------------------------------------------------------
%% Test suite setup/teardown
%% -------------------------------------------------------------------

init_per_group(Group, Config0) ->
    PathConfig = {rabbitmq_management, [{path_prefix, ?PATH_PREFIX}]},
    Config1 = rabbit_ct_helpers:merge_app_env(Config0, PathConfig),
    rabbit_ct_helpers:log_environment(),
    inets:start(),
    ClusterSize = case Group of
                      cluster_size_3 -> 3;
                      cluster_size_5 -> 5;
                      single_node -> 1
                  end,
    NodeConf = [{rmq_nodename_suffix, Group},
                {rmq_nodes_count, ClusterSize},
                {tcp_ports_base}],
    Config2 = rabbit_ct_helpers:set_config(Config1, NodeConf),
    rabbit_ct_helpers:run_setup_steps(
      Config2,
      rabbit_ct_broker_helpers:setup_steps() ++
      rabbit_ct_client_helpers:setup_steps()).

end_per_group(_, Config) ->
    inets:stop(),
    Teardown0 = rabbit_ct_client_helpers:teardown_steps(),
    Teardown1 = rabbit_ct_broker_helpers:teardown_steps(),
    Steps = Teardown0 ++ Teardown1,
    rabbit_ct_helpers:run_teardown_steps(Config, Steps).

init_per_testcase(Testcase, Config) when Testcase == is_quorum_critical_test ->
    case rabbit_ct_helpers:is_mixed_versions() of
        true ->
            {skip, "not mixed versions compatible"};
        _ ->
            rabbit_ct_helpers:testcase_started(Config, Testcase)
    end;
init_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_started(Config, Testcase).

end_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_finished(Config, Testcase).

%% -------------------------------------------------------------------
%% Test cases
%% -------------------------------------------------------------------

health_checks_test(Config) ->
    Port = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_mgmt),
    http_get(Config, "/health/checks/certificate-expiration/1/days", ?OK),
    http_get(Config, io_lib:format("/health/checks/port-listener/~tp", [Port]), ?OK),
    http_get(Config, "/health/checks/protocol-listener/http", ?OK),
    http_get(Config, "/health/checks/virtual-hosts", ?OK),
    http_get(Config, "/health/checks/node-is-quorum-critical", ?OK),
    passed.

metadata_store_initialized_test(Config) ->
    http_get(Config, "/health/checks/metadata-store/initialized", ?OK),
    passed.

metadata_store_initialized_with_data_test(Config) ->
    http_get(Config, "/health/checks/metadata-store/initialized/with-data", ?OK),
    passed.

alarms_test(Config) ->
    Server = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename),
    rabbit_ct_broker_helpers:clear_all_alarms(Config, Server),

    EndpointPath = "/health/checks/alarms",
    Check0 = http_get(Config, EndpointPath, ?OK),
    ?assertEqual(<<"ok">>, maps:get(status, Check0)),

    ok = rabbit_ct_broker_helpers:set_alarm(Config, Server, memory),
    rabbit_ct_helpers:await_condition(
        fun() -> rabbit_ct_broker_helpers:get_alarms(Config, Server) =/= [] end
    ),

    Body = http_get_failed(Config, EndpointPath),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body)),
    ?assert(is_list(maps:get(<<"alarms">>, Body))),

    rabbit_ct_broker_helpers:clear_all_alarms(Config, Server),
    rabbit_ct_helpers:await_condition(
        fun() -> rabbit_ct_broker_helpers:get_alarms(Config, Server) =:= [] end
    ),
    ct:pal("Alarms: ~tp", [rabbit_ct_broker_helpers:get_alarms(Config, Server)]),

    passed.

local_alarms_test(Config) ->
    Server = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename),
    rabbit_ct_broker_helpers:clear_all_alarms(Config, Server),

    EndpointPath = "/health/checks/local-alarms",
    Check0 = http_get(Config, EndpointPath, ?OK),
    ?assertEqual(<<"ok">>, maps:get(status, Check0)),

    ok = rabbit_ct_broker_helpers:set_alarm(Config, Server, file_descriptor_limit),
    rabbit_ct_helpers:await_condition(
        fun() -> rabbit_ct_broker_helpers:get_alarms(Config, Server) =/= [] end
    ),

    Body = http_get_failed(Config, EndpointPath),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body)),
    ?assert(is_list(maps:get(<<"alarms">>, Body))),

    rabbit_ct_broker_helpers:clear_all_alarms(Config, Server),
    rabbit_ct_helpers:await_condition(
        fun() -> rabbit_ct_broker_helpers:get_local_alarms(Config, Server) =:= [] end
    ),

    passed.


is_quorum_critical_single_node_test(Config) ->
    EndpointPath = "/health/checks/node-is-quorum-critical",
    Check0 = http_get(Config, EndpointPath, ?OK),
    ?assertEqual(<<"single node cluster">>, maps:get(reason, Check0)),
    ?assertEqual(<<"ok">>, maps:get(status, Check0)),

    Server = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename),
    Ch = rabbit_ct_client_helpers:open_channel(Config, Server),
    Args = [{<<"x-queue-type">>, longstr, <<"quorum">>}],
    QName = <<"is_quorum_critical_single_node_test">>,
    ?assertEqual({'queue.declare_ok', QName, 0, 0},
                 amqp_channel:call(Ch, #'queue.declare'{queue     = QName,
                                                        durable   = true,
                                                        auto_delete = false,
                                                        arguments = Args})),
    Check1 = http_get(Config, EndpointPath, ?OK),
    ?assertEqual(<<"single node cluster">>, maps:get(reason, Check1)),

    passed.

is_quorum_critical_test(Config) ->
    EndpointPath = "/health/checks/node-is-quorum-critical",
    Check0 = http_get(Config, EndpointPath, ?OK),
    ?assertEqual(false, maps:is_key(reason, Check0)),
    ?assertEqual(<<"ok">>, maps:get(status, Check0)),

    [Server | _] = rabbit_ct_broker_helpers:get_node_configs(Config, nodename),
    Ch = rabbit_ct_client_helpers:open_channel(Config, Server),
    Args = [{<<"x-queue-type">>, longstr, <<"quorum">>},
            {<<"x-quorum-initial-group-size">>, long, 3}],
    QName = <<"is_quorum_critical_test">>,
    ?assertEqual({'queue.declare_ok', QName, 0, 0},
                 amqp_channel:call(Ch, #'queue.declare'{queue     = QName,
                                                        durable   = true,
                                                        auto_delete = false,
                                                        arguments = Args})),
    Check1 = http_get(Config, EndpointPath, ?OK),
    ?assertEqual(false, maps:is_key(reason, Check1)),

    RaName = binary_to_atom(<<"%2F_", QName/binary>>, utf8),
    {ok, [_, {_, Server2}, {_, Server3}], _} = ra:members({RaName, Server}),

    ok = rabbit_ct_broker_helpers:stop_node(Config, Server2),
    ok = rabbit_ct_broker_helpers:stop_node(Config, Server3),

    Body = http_get_failed(Config, EndpointPath),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body)),
    ?assertEqual(true, maps:is_key(<<"reason">>, Body)),
    Queues = maps:get(<<"queues">>, Body),
    ?assert(lists:any(
        fun(Item) ->
            QName =:= maps:get(<<"name">>, Item)
        end, Queues)),

    passed.

quorum_queues_without_elected_leader_single_node_test(Config) ->
    EndpointPath = "/health/checks/quorum-queues-without-elected-leaders/all-vhosts/",
    Check0 = http_get(Config, EndpointPath, ?OK),
    ?assertEqual(false, maps:is_key(reason, Check0)),
    ?assertEqual(<<"ok">>, maps:get(status, Check0)),

    [Server | _] = rabbit_ct_broker_helpers:get_node_configs(Config, nodename),
    Ch = rabbit_ct_client_helpers:open_channel(Config, Server),
    Args = [{<<"x-queue-type">>, longstr, <<"quorum">>},
            {<<"x-quorum-initial-group-size">>, long, 3}],
    QName = <<"quorum_queues_without_elected_leader">>,
    ?assertEqual({'queue.declare_ok', QName, 0, 0},
        amqp_channel:call(Ch, #'queue.declare'{
            queue       = QName,
            durable     = true,
            auto_delete = false,
            arguments   = Args
        })),

    Check1 = http_get(Config, EndpointPath, ?OK),
    ?assertEqual(false, maps:is_key(reason, Check1)),

    RaSystem = quorum_queues,
    QResource = rabbit_misc:r(<<"/">>, queue, QName),
    {ok, Q1} = rabbit_ct_broker_helpers:rpc(Config, 0, rabbit_db_queue, get, [QResource]),

    _ = rabbit_ct_broker_helpers:rpc(Config, 0, ra, stop_server, [RaSystem, amqqueue:get_pid(Q1)]),

    Body = http_get_failed(Config, EndpointPath),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body)),
    ?assertEqual(true, maps:is_key(<<"reason">>, Body)),
    Queues = maps:get(<<"queues">>, Body),
    ?assert(lists:any(
        fun(Item) ->
            QName =:= maps:get(<<"name">>, Item)
        end, Queues)),

    _ = rabbit_ct_broker_helpers:rpc(Config, 0, ra, restart_server, [RaSystem, amqqueue:get_pid(Q1)]),
    rabbit_ct_helpers:await_condition(
        fun() ->
            try
                Check2 = http_get(Config, EndpointPath, ?OK),
                false =:= maps:is_key(reason, Check2)
            catch _:_ ->
                false
            end
        end),

    passed.

quorum_queues_without_elected_leader_across_all_virtual_hosts_single_node_test(Config) ->
    VH2 = <<"vh-2">>,
    rabbit_ct_broker_helpers:add_vhost(Config, VH2),

    EndpointPath1 = "/health/checks/quorum-queues-without-elected-leaders/vhost/%2f/",
    EndpointPath2 = "/health/checks/quorum-queues-without-elected-leaders/vhost/vh-2/",
    %% ^other
    EndpointPath3 = "/health/checks/quorum-queues-without-elected-leaders/vhost/vh-2/pattern/%5Eother",

    Check0 = http_get(Config, EndpointPath1, ?OK),
    Check0 = http_get(Config, EndpointPath2, ?OK),
    ?assertEqual(false, maps:is_key(reason, Check0)),
    ?assertEqual(<<"ok">>, maps:get(status, Check0)),

    [Server | _] = rabbit_ct_broker_helpers:get_node_configs(Config, nodename),
    Ch = rabbit_ct_client_helpers:open_channel(Config, Server),
    Args = [{<<"x-queue-type">>, longstr, <<"quorum">>},
        {<<"x-quorum-initial-group-size">>, long, 3}],
    QName = <<"quorum_queues_without_elected_leader_across_all_virtual_hosts_single_node_test">>,
    ?assertEqual({'queue.declare_ok', QName, 0, 0},
        amqp_channel:call(Ch, #'queue.declare'{
            queue       = QName,
            durable     = true,
            auto_delete = false,
            arguments   = Args
        })),

    Check1 = http_get(Config, EndpointPath1, ?OK),
    ?assertEqual(false, maps:is_key(reason, Check1)),

    RaSystem = quorum_queues,
    QResource = rabbit_misc:r(<<"/">>, queue, QName),
    {ok, Q1} = rabbit_ct_broker_helpers:rpc(Config, 0, rabbit_db_queue, get, [QResource]),

    _ = rabbit_ct_broker_helpers:rpc(Config, 0, ra, stop_server, [RaSystem, amqqueue:get_pid(Q1)]),

    Body = http_get_failed(Config, EndpointPath1),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body)),
    ?assertEqual(true, maps:is_key(<<"reason">>, Body)),
    Queues = maps:get(<<"queues">>, Body),
    ?assert(lists:any(
        fun(Item) ->
            QName =:= maps:get(<<"name">>, Item)
        end, Queues)),

    %% virtual host vh-2 is still fine
    Check2 = http_get(Config, EndpointPath2, ?OK),
    ?assertEqual(false, maps:is_key(reason, Check2)),

    %% a different queue name pattern succeeds
    Check3 = http_get(Config, EndpointPath3, ?OK),
    ?assertEqual(false, maps:is_key(reason, Check3)),

    _ = rabbit_ct_broker_helpers:rpc(Config, 0, ra, restart_server, [RaSystem, amqqueue:get_pid(Q1)]),
    rabbit_ct_helpers:await_condition(
        fun() ->
            try
                Check4 = http_get(Config, EndpointPath1, ?OK),
                false =:= maps:is_key(reason, Check4)
            catch _:_ ->
                false
            end
        end),

    rabbit_ct_broker_helpers:delete_vhost(Config, VH2),

    passed.


virtual_hosts_test(Config) ->
    VHost1 = <<"vhost1">>,
    VHost2 = <<"vhost2">>,
    add_vhost(Config, VHost1),
    add_vhost(Config, VHost2),

    Path = "/health/checks/virtual-hosts",
    Check0 = http_get(Config, Path, ?OK),
    ?assertEqual(<<"ok">>, maps:get(status, Check0)),

    rabbit_ct_broker_helpers:force_vhost_failure(Config, VHost1),

    Body1 = http_get_failed(Config, Path),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body1)),
    ?assertEqual(true, maps:is_key(<<"reason">>, Body1)),
    ?assertEqual([VHost1], maps:get(<<"virtual-hosts">>, Body1)),

    rabbit_ct_broker_helpers:force_vhost_failure(Config, VHost2),

    Body2 = http_get_failed(Config, Path),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body2)),
    ?assertEqual(true, maps:is_key(<<"reason">>, Body2)),
    VHosts = lists:sort([VHost1, VHost2]),
    ?assertEqual(VHosts, lists:sort(maps:get(<<"virtual-hosts">>, Body2))),

    rabbit_ct_broker_helpers:delete_vhost(Config, VHost1),
    rabbit_ct_broker_helpers:delete_vhost(Config, VHost2),
    http_get(Config, Path, ?OK),

    passed.

protocol_listener_test(Config) ->
    Check0 = http_get(Config, "/health/checks/protocol-listener/http", ?OK),
    ?assertEqual(<<"ok">>, maps:get(status, Check0)),

    http_get(Config, "/health/checks/protocol-listener/amqp", ?OK),
    http_get(Config, "/health/checks/protocol-listener/amqp0.9.1", ?OK),
    http_get(Config, "/health/checks/protocol-listener/amqp0-9-1", ?OK),

    Body0 = http_get_failed(Config, "/health/checks/protocol-listener/mqtt"),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body0)),
    ?assertEqual(true, maps:is_key(<<"reason">>, Body0)),
    ?assertEqual([<<"mqtt">>], maps:get(<<"missing">>, Body0)),
    ?assert(lists:member(<<"http">>, maps:get(<<"protocols">>, Body0))),
    ?assert(lists:member(<<"clustering">>, maps:get(<<"protocols">>, Body0))),
    ?assert(lists:member(<<"amqp">>, maps:get(<<"protocols">>, Body0))),

    http_get_failed(Config, "/health/checks/protocol-listener/doe"),
    http_get_failed(Config, "/health/checks/protocol-listener/mqtts"),
    http_get_failed(Config, "/health/checks/protocol-listener/stomp"),
    http_get_failed(Config, "/health/checks/protocol-listener/stomp1.0"),

    %% Multiple protocols may be supplied. The health check only returns OK if
    %% all requested protocols are available.
    Body1 = http_get_failed(Config, "/health/checks/protocol-listener/amqp,mqtt"),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body1)),
    ?assertEqual(true, maps:is_key(<<"reason">>, Body1)),
    ?assert(lists:member(<<"mqtt">>, maps:get(<<"missing">>, Body1))),
    ?assert(lists:member(<<"amqp">>, maps:get(<<"protocols">>, Body1))),

    passed.

port_listener_test(Config) ->
    AMQP = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_amqp),
    MGMT = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_mgmt),
    MQTT = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_mqtt),

    Path = fun(Port) ->
                   lists:flatten(io_lib:format("/health/checks/port-listener/~tp", [Port]))
           end,

    Check0 = http_get(Config, Path(AMQP), ?OK),
    ?assertEqual(<<"ok">>, maps:get(status, Check0)),

    Check1 = http_get(Config, Path(MGMT), ?OK),
    ?assertEqual(<<"ok">>, maps:get(status, Check1)),

    http_get(Config, "/health/checks/port-listener/bananas", ?BAD_REQUEST),

    Body0 = http_get_failed(Config, Path(MQTT)),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body0)),
    ?assertEqual(true, maps:is_key(<<"reason">>, Body0)),
    ?assertEqual(MQTT, maps:get(<<"missing">>, Body0)),
    ?assert(lists:member(AMQP, maps:get(<<"ports">>, Body0))),
    ?assert(lists:member(MGMT, maps:get(<<"ports">>, Body0))),

    passed.

certificate_expiration_test(Config) ->
    Check0 = http_get(Config, "/health/checks/certificate-expiration/1/weeks", ?OK),
    ?assertEqual(<<"ok">>, maps:get(status, Check0)),

    http_get(Config, "/health/checks/certificate-expiration/1/days", ?OK),
    http_get(Config, "/health/checks/certificate-expiration/1/months", ?OK),

    http_get(Config, "/health/checks/certificate-expiration/two/weeks", ?BAD_REQUEST),
    http_get(Config, "/health/checks/certificate-expiration/2/week", ?BAD_REQUEST),
    http_get(Config, "/health/checks/certificate-expiration/2/doe", ?BAD_REQUEST),

    Body0 = http_get_failed(Config, "/health/checks/certificate-expiration/10/years"),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body0)),
    ?assertEqual(true, maps:is_key(<<"reason">>, Body0)),
    [Expired] = maps:get(<<"expired">>, Body0),
    ?assertEqual(<<"amqp/ssl">>, maps:get(<<"protocol">>, Expired)),
    AMQP_TLS = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_amqp_tls),
    ?assertEqual(AMQP_TLS, maps:get(<<"port">>, Expired)),
    Node = atom_to_binary(rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename), utf8),
    ?assertEqual(Node, maps:get(<<"node">>, Expired)),
    ?assertEqual(true, maps:is_key(<<"cacertfile">>, Expired)),
    ?assertEqual(true, maps:is_key(<<"certfile">>, Expired)),
    ?assertEqual(true, maps:is_key(<<"certfile_expires_on">>, Expired)),
    ?assertEqual(true, maps:is_key(<<"interface">>, Expired)),

    passed.

is_in_service_test(Config) ->
    Path = "/health/checks/is-in-service",
    Check0 = http_get(Config, Path, ?OK),
    ?assertEqual(<<"ok">>, maps:get(status, Check0)),

    true = rabbit_ct_broker_helpers:mark_as_being_drained(Config, 0),
    Body0 = http_get_failed(Config, Path),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body0)),
    true = rabbit_ct_broker_helpers:unmark_as_being_drained(Config, 0),

    passed.

below_node_connection_limit_test(Config) ->
    Path = "/health/checks/below-node-connection-limit",
    Check0 = http_get(Config, Path, ?OK),
    ?assertEqual(<<"ok">>, maps:get(status, Check0)),

    %% Set the connection limit low and open 'limit' connections.
    rabbit_ct_client_helpers:close_channels_and_connection(Config, 0),
    Limit = 10,
    rabbit_ct_broker_helpers:rpc(
      Config, 0, application, set_env, [rabbit, connection_max, Limit]),
    Connections = [rabbit_ct_client_helpers:open_unmanaged_connection(Config, 0) || _ <- lists:seq(1, Limit)],
    true = lists:all(fun(E) -> is_pid(E) end, Connections),
    {error, not_allowed} = rabbit_ct_client_helpers:open_unmanaged_connection(Config, 0),

    Body0 = http_get_failed(Config, Path),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body0)),

    %% Clean up the connections and reset the limit.
    [catch rabbit_ct_client_helpers:close_connection(C) || C <- Connections],
    rabbit_ct_broker_helpers:rpc(
      Config, 0, application, set_env, [rabbit, connection_max, infinity]),

    passed.

ready_to_serve_clients_test(Config) ->
    Path = "/health/checks/ready-to-serve-clients",
    Check0 = http_get(Config, Path, ?OK),
    ?assertEqual(<<"ok">>, maps:get(status, Check0)),

    true = rabbit_ct_broker_helpers:mark_as_being_drained(Config, 0),
    Body0 = http_get_failed(Config, Path),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body0)),
    true = rabbit_ct_broker_helpers:unmark_as_being_drained(Config, 0),

    %% Set the connection limit low and open 'limit' connections.
    rabbit_ct_client_helpers:close_channels_and_connection(Config, 0),
    Limit = 10,
    rabbit_ct_broker_helpers:rpc(
      Config, 0, application, set_env, [rabbit, connection_max, Limit]),
    Connections = [rabbit_ct_client_helpers:open_unmanaged_connection(Config, 0) || _ <- lists:seq(1, Limit)],
    true = lists:all(fun(E) -> is_pid(E) end, Connections),
    {error, not_allowed} = rabbit_ct_client_helpers:open_unmanaged_connection(Config, 0),

    Body1 = http_get_failed(Config, Path),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Body1)),

    %% Clean up the connections and reset the limit.
    [catch rabbit_ct_client_helpers:close_connection(C) || C <- Connections],
    rabbit_ct_broker_helpers:rpc(
      Config, 0, application, set_env, [rabbit, connection_max, infinity]),

    passed.

http_get_failed(Config, Path) ->
    {ok, {{_, Code, _}, _, ResBody}} = req(Config, get, Path, [auth_header("guest", "guest")]),
    ct:pal("GET ~s: ~w ~w", [Path, Code, ResBody]),
    ?assertEqual(Code, ?HEALTH_CHECK_FAILURE_STATUS),
    rabbit_json:decode(rabbit_data_coercion:to_binary(ResBody)).

delete_queues() ->
    [rabbit_amqqueue:delete(Q, false, false, <<"dummy">>)
     || Q <- rabbit_amqqueue:list()].

add_vhost(Config, VHost) ->
    rabbit_ct_broker_helpers:add_vhost(Config, VHost),
    rabbit_ct_broker_helpers:set_full_permissions(Config, <<"guest">>, VHost).
