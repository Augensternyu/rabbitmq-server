PROJECT = rabbitmq_shovel
PROJECT_DESCRIPTION = Data Shovel for RabbitMQ
PROJECT_MOD = rabbit_shovel

define PROJECT_ENV
[
	    {defaults, [
	        {prefetch_count,     1000},
	        {ack_mode,           on_confirm},
	        {publish_fields,     []},
	        {publish_properties, []},
	        {reconnect_delay,    5}
	      ]}
	  ]
endef

define PROJECT_APP_EXTRA_KEYS
	{broker_version_requirements, []}
endef

DEPS = rabbit_common rabbit amqp_client amqp10_client
dep_amqp10_client = git https://github.com/rabbitmq/rabbitmq-amqp1.0-client.git master

LOCAL_DEPS = crypto

TEST_DEPS = rabbitmq_ct_helpers rabbitmq_ct_client_helpers rabbitmq_amqp1_0 rabbitmq_amqp_client meck

PLT_APPS += rabbitmq_cli

DEP_EARLY_PLUGINS = rabbit_common/mk/rabbitmq-early-plugin.mk
DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk elvis_mk
dep_elvis_mk = git https://github.com/inaka/elvis.mk.git master

include ../../rabbitmq-components.mk
include ../../erlang.mk
