# frozen_string_literal: true

#
# Copyright (C) 2026, Tensibai
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module Kitchen
  module Driver
    # Version of the kitchen-scaleway gem.
    #
    # Kept in its own file so the gemspec can read it without loading the
    # driver, and so `release-please` has a single line to bump.
    #
    # @return [String] a semantic version string
    SCALEWAY_VERSION = "0.1.0"
  end
end
