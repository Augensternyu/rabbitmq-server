#!/usr/bin/env bash

SCRIPT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

TEST_CASES_PATH=/oauth/with-idp-initiated-via-proxy
TEST_CONFIG_PATH=/oauth
PROFILES="uaa fakeportal fakeproxy fakeportal-oauth-provider idp-initiated"

source $SCRIPT/../bin/suite_template $@
runWith uaa fakeportal fakeproxy
