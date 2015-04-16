#
# Fluentd
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

require 'fluent/plugin/output'
require 'fluent/plugin/buffered_output'
require 'fluent/plugin/object_buffered_output'
require 'fluent/plugin/time_sliced_output'

# This classes are for compatibility.
# Fluent::Input (or other plugin base classes) are obsolete in v0.14.

require 'fluent/plugin_support/emitter'

module Fluent
  class EngineCompat
    def initialize
      @router = nil
    end

    def reconfigure
      @router = Fluent::Engine.root_agent.event_router
    end

    def emit(tag, time, record)
      @router.emit(tag, time, record)
    end

    def emit_array(tag, array)
      @router.emit(tag, array)
    end

    def emit_stream(tag, es)
      @router.emit_stream(tag, es)
    end
  end

  module OutputPluginCompat
    # TODO: add interoperability layer (especially for chain)

    # All traditional output plugins can emit events
    include Fluent::PluginSupport::Emitter

    # to overwrite Fluent::Engine in traditional plugin code
    module Fluent; end

    Fluent::Engine = Engine = EngineCompat.new # Engine.root_agent is not initialized yet

    def configure(conf)
      super
      # set root_agent.event_router here
      Engine.reconfigure
    end
  end

  class Output < Plugin::Output
    include OutputPluginCompat
  end

  class BufferedOutput < Plugin::BufferedOutput
    include OutputPluginCompat
  end

  class ObjectBufferedOutput < Plugin::ObjectBufferedOutput
    include OutputPluginCompat
  end

  class TimeSlicedOutput < Plugin::TimeSlicedOutput
    include OutputPluginCompat
  end

  class MultiOutput < Output
    #def outputs
    #end
  end

  # Output Chain does nothing currently.
  # These will be removed at v1.
  class OutputChain
    def initialize(array, tag, es, chain=NullOutputChain.instance)
      @array = array
      @tag = tag
      @es = es
      @offset = 0
      @chain = chain
    end

    def next
      if @array.length <= @offset
        return @chain.next
      end
      @offset += 1
      result = @array[@offset-1].emit(@tag, @es, self)
      result
    end
  end

  class CopyOutputChain < OutputChain
    def next
      if @array.length <= @offset
        return @chain.next
      end
      @offset += 1
      es = @array.length > @offset ? @es.dup : @es
      result = @array[@offset-1].emit(@tag, es, self)
      result
    end
  end

  class NullOutputChain
    require 'singleton'
    include Singleton

    def next
    end
  end
end

