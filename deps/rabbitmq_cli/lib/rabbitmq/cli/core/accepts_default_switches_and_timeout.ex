## This Source Code Form is subject to the terms of the Mozilla Public
## License, v. 2.0. If a copy of the MPL was not distributed with this
## file, You can obtain one at https://mozilla.org/MPL/2.0/.
##
## Copyright (c) 2007-2025 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries.  All rights reserved.

# Should be used by commands that require rabbit app to be stopped
# but need no other execution environment validators.
defmodule RabbitMQ.CLI.Core.AcceptsDefaultSwitchesAndTimeout do
  defmacro __using__(_) do
    quote do
      def switches(), do: [timeout: :integer]
      def aliases(), do: [t: :timeout]
    end
  end
end
