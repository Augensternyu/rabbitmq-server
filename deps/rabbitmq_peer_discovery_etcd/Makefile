PROJECT = rabbitmq_peer_discovery_etcd
PROJECT_DESCRIPTION = etcd-based RabbitMQ peer discovery backend

DEPS = rabbit_common rabbitmq_peer_discovery_common rabbit eetcd gun
TEST_DEPS = rabbitmq_ct_helpers rabbitmq_ct_client_helpers ct_helper meck
dep_ct_helper = git https://github.com/extend/ct_helper.git master
dep_eetcd = hex 0.5.0

DEP_EARLY_PLUGINS = rabbit_common/mk/rabbitmq-early-plugin.mk
DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

include ../../rabbitmq-components.mk
include ../../erlang.mk
