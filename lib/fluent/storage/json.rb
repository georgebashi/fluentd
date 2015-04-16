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

require 'fluent/storage/base'
require 'fluent/plugin'
require 'fluent/env'

require 'json'
require 'fileutils'

module Fluent
  module Storage
    class JSON < Base
      Fluent::Plugin.register_storage('json', self)

      config_section :storage, required: false, multi: false, param_name: :storage_config do
        config_param :path, :string
        config_param :permission, :integer, default: DEFAULT_FILE_PERMISSION
        config_param :directory_permission, :integer, default: DEFAULT_DIR_PERMISSION
        config_param :pretty_print, :bool, default: true
      end

      def initialize
        super
        @store = {}
      end

      def configure(conf)
        super

        @path = @storage_config.path
        @perm = @storage_config.permission
        @dirperm = @storage_config.directory_permission
        @tmp_path = @path + '.tmp'
        @pretty_print = @storage_config.pretty_print
      end

      def load
        unless FileTest.exist?(@path)
          @store = {}
          return
        end

        unless FileTest.file?(@path)
          raise LoadError, "specified json storage file path is not a normal file: '#{@path}'"
        end
        unless FileTest.readable?(@path)
          raise LoadError, "specified json storage path is not readable/writable: '#{@path}'"
        end

        begin
          synchronize do
            json_string = open(@path, 'r:utf-8') { |io| io.read }
            @store = ::JSON.parse(json_string, symbolize_names: true)
          end
        rescue IOError => e
          raise LoadError, "IOError: " + e.message
        rescue SystemCallError => e
          raise LoadError, "SystemCallError(#{e.class}): " + e.message
        rescue ::JSON::ParserError => e
          raise LoadError, "ParserError: " + e.message
        end

        self
      end

      def save
        begin
          synchronize do
            json_string = if @pretty_print
                            ::JSON.pretty_generate(@store)
                          else
                            ::JSON.generate(@store)
                          end
            FileUtils.mkdir_p(File.dirname(@tmp_path), mode: @dirperm)
            open(@tmp_path, 'w:utf-8', @perm) do |io|
              io.write json_string
            end
            File.rename(@tmp_path, @path)
          end
        rescue IOError => e
          raise SaveError, "IOError: " + e.message
        rescue SystemCallError => e
          raise SaveError, "SystemCallError(#{e.class}): " + e.message
        rescue ::JSON::GeneratorError => e
          raise SaveError, "GeneratorError: " + e.message
        end

        self
      end

      def put(key, value)
        synchronize do
          @store[key.to_sym] = value
        end
      end

      def get(key)
        synchronize do
          @store[key.to_sym]
        end
      end

      def fetch(key, default_value)
        synchronize do
          @store.fetch(key.to_sym, default_value)
        end
      end

      def delete(key)
        synchronize do
          @store.delete(key.to_sym)
        end
      end
    end
  end
end
