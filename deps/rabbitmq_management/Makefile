PROJECT = rabbitmq_management
PROJECT_DESCRIPTION = RabbitMQ Management Console
PROJECT_MOD = rabbit_mgmt_app

define PROJECT_ENV
[
	    {http_log_dir,      none},
	    {load_definitions,  none},
	    {management_db_cache_multiplier, 5},
	    {process_stats_gc_timeout, 300000},
	    {stats_event_max_backlog, 250},

	    {cors_allow_origins, []},
	    {cors_max_age, 1800},
	    {content_security_policy, "script-src 'self' 'unsafe-eval' 'unsafe-inline'; object-src 'self'"},
	    {max_http_body_size, 10000000},
	    {delegate_count, 5},
	    {require_auth_for_api_reference, false}
	  ]
endef

define PROJECT_APP_EXTRA_KEYS
	{broker_version_requirements, []}
endef

DEPS = rabbit_common rabbit amqp_client cowboy cowlib rabbitmq_web_dispatch rabbitmq_management_agent oauth2_client
TEST_DEPS = rabbitmq_ct_helpers rabbitmq_ct_client_helpers proper rabbitmq_amqp_client
LOCAL_DEPS += ranch ssl crypto public_key

# FIXME: Add Ranch as a BUILD_DEPS to be sure the correct version is picked.
# See rabbitmq-components.mk.
BUILD_DEPS += ranch

CT_HOOKS = rabbit_ct_hook
DEP_EARLY_PLUGINS = rabbit_common/mk/rabbitmq-early-plugin.mk
DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

include ../../rabbitmq-components.mk
include ../../erlang.mk

# --------------------------------------------------------------------
# Distribution.
# --------------------------------------------------------------------

list-dist-deps::
	@echo bin/rabbitmqadmin

prepare-dist::
	$(verbose) sed 's/%%VSN%%/$(PROJECT_VERSION)/' bin/rabbitmqadmin \
		> $(EZ_DIR)/priv/www/cli/rabbitmqadmin
