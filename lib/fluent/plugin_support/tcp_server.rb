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

require 'fluent/plugin_support/event_loop'
require 'fluent/plugin_support/timer'
require 'fluent/plugin_support/socket'

require 'socket'
require 'cool.io'

module Fluent
  module PluginSupport
    module TCPServer
      include Fluent::PluginSupport::EventLoop
      include Fluent::PluginSupport::Timer
      include Fluent::PluginSupport::Socket

      TCP_SERVER_KEEPALIVE_CHECK_INTERVAL = 1

      # keepalive: seconds, (default: nil [inf])
      def tcp_server_listen(port:, bind: '0.0.0.0', keepalive: nil, linger_timeout: nil, backlog: nil, &block)
        raise "BUG: callback block is not specified for tcp_server_listen" unless block_given?
        port = port.to_i

        socket_listener_add('tcp', bind, port)

        bind_sock = ::TCPServer.new(bind, port)

        if self.respond_to?(:detach_multi_process)
          detach_multi_process do
            tcp_server_listen_impl(bind, port, bind_sock, keepalive, linger_timeout, backlog, &block)
          end
        elsif self.respond_to?(:detach_process)
          detach_process do
            tcp_server_listen_impl(bind, port, bind_sock, keepalive, linger_timeout, backlog, &block)
          end
        else
          tcp_server_listen_impl(bind, port, bind_sock, keepalive, linger_timeout, backlog, &block)
        end
      end

      def initialize
        super
        @_tcp_server_listen_socks = []
        @_tcp_server_connections = {}
      end

      def configure(conf)
        super
      end

      def stop
        super
      end

      def shutdown
        @_tcp_server_listen_socks.each do |s|
          s.detach if s.attached?
        end
        @_tcp_server_connections.keys.each do |sock|
          sock.detach if sock.attached?
        end

        super
      end

      def close
        @_tcp_server_connections.keys.each do |sock|
          sock.close unless sock.closed?
        end
        @_tcp_server_listen_socks.each{|s| s.close }

        super
      end

      def terminate
        @_tcp_server_listen_socks = []
        @_tcp_server_connections = {}

        super
      end

      def tcp_server_listen_impl(bind, port, bind_sock, keepalive, linger_timeout, backlog, &block)
        register_new_connection = ->(conn){ @_tcp_server_connections[conn] = conn }

        timer_execute(interval: TCP_SERVER_KEEPALIVE_CHECK_INTERVAL, repeat: true) do
          # copy keys at first (to delete it in loop)
          @_tcp_server_connections.keys.each do |conn|
            if !conn.writing? && keepalive && conn.idle_seconds > keepalive
              @_tcp_server_connections.delete(conn)
              conn.close
            elsif conn.closed?
              @_tcp_server_connections.delete(conn)
            else
              conn.idle_seconds += TCP_SERVER_KEEPALIVE_CHECK_INTERVAL
            end
          end
        end

        sock = Coolio::TCPServer.new(bind_sock, nil, Handler, register_new_connection, linger_timeout, block)
        if backlog
          sock.listen(backlog)
        end
        socket_listener_listen('tcp', bind, port)
        event_loop_attach( sock )
        @_tcp_server_listen_socks << sock
      end

      class Handler < Coolio::Socket
        attr_accessor :idle_seconds, :closing
        attr_reader :protocol, :remote_port, :remote_addr, :remote_host

        PEERADDR_FAILED = ["?", "?", "name resolusion failed", "?"]

        def initialize(io, register, linger_timeout, on_connect_callback)
          super(io)

          register.call(self)
          @on_connect_callback = on_connect_callback
          @on_read_callback = nil

          @buffer = nil # for on_data with delimiter

          @idle_seconds = 0
          @closing = false
          @writing = false

          ### TODO: disabling name rev resolv
          proto, port, host, addr = ( io.peeraddr rescue PEERADDR_FAILED )
          if addr == '?'
            port, addr = *Socket.unpack_sockaddr_in(io.getpeername) rescue nil
          end
          @protocol = proto
          @remote_port = port
          @remote_addr = addr
          @remote_host = host

          if linger_timeout
            # SO_LINGER 0 to send RST rather than FIN to avoid lots of connections sitting in TIME_WAIT at src
            opt = [1, linger_timeout].pack('I!I!')  # { int l_onoff; int l_linger; }
            io.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_LINGER, opt)
          end
        end

        def on_connect
          @on_connect_callback.call(self)
        end

        # API to register callback for data arrival
        def on_data(delimiter: nil, &callback)
          if delimiter.nil?
            @on_read_callback = callback
          else # buffering and splitting
            @buffer = "".force_encoding("ASCII-8BIT")
            @on_read_callback = ->(data) {
              @buffer << data
              pos = 0
              while i = @buffer.index(delimiter, pos)
                msg = @buffer[pos...i]
                callback.call(msg)
                pos = i + delimiter.length
              end
              @buffer.slice!(0, pos) if pos > 0
            }
          end
        end

        def on_read(data)
          @idle_seconds = 0
          @on_read_callback.call(data)
        rescue => e
          close
          #### TODO: error handling & logging
          raise
        end

        def write(data)
          @writing = true
          super
        end

        def writing?
          @writing
        end

        def on_write_complete
          @writing = false
          if @closing
            close
          end
        end

        def close
          @closing = true
          unless @writing
            super
          end
        end
      end
    end
  end
end
