# encoding: binary
#  Phusion Passenger - http://www.modrails.com/
#  Copyright (c) 2008, 2009 Phusion
#
#  "Phusion Passenger" is a trademark of Hongli Lai & Ninh Bui.
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.

require 'socket'
require 'fcntl'
require 'phusion_passenger/message_channel'
require 'phusion_passenger/utils'
require 'phusion_passenger/utils/unseekable_socket'
require 'phusion_passenger/utils/message_client'
require 'phusion_passenger/constants'
module PhusionPassenger

# The request handler is the layer which connects Apache with the underlying application's
# request dispatcher (i.e. either Rails's Dispatcher class or Rack).
# The request handler's job is to process incoming HTTP requests using the
# currently loaded Ruby on Rails application. HTTP requests are forwarded
# to the request handler by the web server. HTTP responses generated by the
# RoR application are forwarded to the web server, which, in turn, sends the
# response back to the HTTP client.
#
# AbstractRequestHandler is an abstract base class for easing the implementation
# of request handlers for Rails and Rack.
#
# == Design decisions
#
# Some design decisions are made because we want to decrease system
# administrator maintenance overhead. These decisions are documented
# in this section.
#
# === Owner pipes
#
# Because only the web server communicates directly with a request handler,
# we want the request handler to exit if the web server has also exited.
# This is implemented by using a so-called _owner pipe_. The writable part
# of the pipe will be passed to the web server* via a Unix socket, and the web
# server will own that part of the pipe, while AbstractRequestHandler owns
# the readable part of the pipe. AbstractRequestHandler will continuously
# check whether the other side of the pipe has been closed. If so, then it
# knows that the web server has exited, and so the request handler will exit
# as well. This works even if the web server gets killed by SIGKILL.
#
# * It might also be passed to the ApplicationPoolServerExecutable, if the web
#   server's using ApplicationPoolServer instead of StandardApplicationPool.
#
#
# == Request format
#
# Incoming "HTTP requests" are not true HTTP requests, i.e. their binary
# representation do not conform to RFC 2616. Instead, the request format
# is based on CGI, and is similar to that of SCGI.
#
# The format consists of 3 parts:
# - A 32-bit big-endian integer, containing the size of the transformed
#   headers.
# - The transformed HTTP headers.
# - The verbatim (untransformed) HTTP request body.
#
# HTTP headers are transformed to a format that satisfies the following
# grammar:
#
#  headers ::= header*
#  header ::= name NUL value NUL
#  name ::= notnull+
#  value ::= notnull+
#  notnull ::= "\x01" | "\x02" | "\x02" | ... | "\xFF"
#  NUL = "\x00"
#
# The web server transforms the HTTP request to the aforementioned format,
# and sends it to the request handler.
class AbstractRequestHandler
	# Signal which will cause the Rails application to exit immediately.
	HARD_TERMINATION_SIGNAL = "SIGTERM"
	# Signal which will cause the Rails application to exit as soon as it's done processing a request.
	SOFT_TERMINATION_SIGNAL = "SIGUSR1"
	BACKLOG_SIZE    = 500
	MAX_HEADER_SIZE = 128 * 1024
	
	# String constants which exist to relieve Ruby's garbage collector.
	IGNORE              = 'IGNORE'              # :nodoc:
	DEFAULT             = 'DEFAULT'             # :nodoc:
	X_POWERED_BY        = 'X-Powered-By'        # :nodoc:
	REQUEST_METHOD      = 'REQUEST_METHOD'      # :nodoc:
	PING                = 'PING'                # :nodoc:
	PASSENGER_CONNECT_PASSWORD = "PASSENGER_CONNECT_PASSWORD"   # :nodoc:
	
	# A hash containing all server sockets that this request handler listens on.
	# The hash is in the form of:
	#
	#   {
	#      name1 => [socket_address1, socket_type1, socket1],
	#      name2 => [socket_address2, socket_type2, socket2],
	#      ...
	#   }
	#
	# +name+ is a Symbol. +socket_addressx+ is the address of the socket,
	# +socket_typex+ is the socket's type (either 'unix' or 'tcp') and
	# +socketx+ is the actual socket IO objec.
	# There's guaranteed to be at least one server socket, namely one with the
	# name +:main+.
	attr_reader :server_sockets
	
	# Specifies the maximum allowed memory usage, in MB. If after having processed
	# a request AbstractRequestHandler detects that memory usage has risen above
	# this limit, then it will gracefully exit (that is, exit after having processed
	# all pending requests).
	#
	# A value of 0 (the default) indicates that there's no limit.
	attr_accessor :memory_limit
	
	# The number of times the main loop has iterated so far. Mostly useful
	# for unit test assertions.
	attr_reader :iterations
	
	# Number of requests processed so far. This includes requests that raised
	# exceptions.
	attr_reader :processed_requests
	
	# If a soft termination signal was received, then the main loop will quit
	# the given amount of seconds after the last time a connection was accepted.
	# Defaults to 3 seconds.
	attr_accessor :soft_termination_linger_time
	
	# A password with which clients must authenticate. Default is unauthenticated.
	attr_accessor :connect_password
	
	# Stream to write error messages to. Defaults to STDERR.
	attr_accessor :stderr
	
	# Create a new RequestHandler with the given owner pipe.
	# +owner_pipe+ must be the readable part of a pipe IO object.
	#
	# Additionally, the following options may be given:
	# - memory_limit: Used to set the +memory_limit+ attribute.
	# - detach_key
	# - connect_password
	# - pool_account_username
	# - pool_account_password_base64
	def initialize(owner_pipe, options = {})
		@server_sockets = {}
		
		if should_use_unix_sockets?
			@main_socket_address, @main_socket = create_unix_socket_on_filesystem
			@server_sockets[:main] = [@main_socket_address, 'unix', @main_socket]
		else
			@main_socket_address, @main_socket = create_tcp_socket
			@server_sockets[:main] = [@main_socket_address, 'tcp', @main_socket]
		end
		
		@http_socket_address, @http_socket = create_tcp_socket
		@server_sockets[:http] = [@http_socket_address, 'tcp', @http_socket]
		
		@owner_pipe = owner_pipe
		@previous_signal_handlers = {}
		@main_loop_generation  = 0
		@main_loop_thread_lock = Mutex.new
		@main_loop_thread_cond = ConditionVariable.new
		@memory_limit          = options["memory_limit"] || 0
		@connect_password      = options["connect_password"]
		@detach_key            = options["detach_key"]
		@pool_account_username = options["pool_account_username"]
		if options["pool_account_password_base64"]
			@pool_account_password = options["pool_account_password_base64"].unpack('m').first
		end
		@iterations         = 0
		@processed_requests = 0
		@soft_termination_linger_time = 3
		@stderr             = STDERR
		@main_loop_running  = false
		
		#############
	end
	
	# Clean up temporary stuff created by the request handler.
	#
	# If the main loop was started by #main_loop, then this method may only
	# be called after the main loop has exited.
	#
	# If the main loop was started by #start_main_loop_thread, then this method
	# may be called at any time, and it will stop the main loop thread.
	def cleanup
		if @main_loop_thread
			@main_loop_thread_lock.synchronize do
				@graceful_termination_pipe[1].close rescue nil
			end
			@main_loop_thread.join
		end
		@server_sockets.each_value do |value|
			address, type, socket = value
			socket.close rescue nil
			if type == 'unix'
				File.unlink(address) rescue nil
			end
		end
		@owner_pipe.close rescue nil
	end
	
	# Check whether the main loop's currently running.
	def main_loop_running?
		return @main_loop_running
	end
	
	# Enter the request handler's main loop.
	def main_loop
		reset_signal_handlers
		begin
			@graceful_termination_pipe = IO.pipe
			@graceful_termination_pipe[0].close_on_exec!
			@graceful_termination_pipe[1].close_on_exec!
			
			@main_loop_thread_lock.synchronize do
				@main_loop_generation += 1
				@main_loop_running = true
				@main_loop_thread_cond.broadcast
				
				@select_timeout = nil
				
				@selectable_sockets = []
				@server_sockets.each_value do |value|
					@selectable_sockets << value[2]
				end
				@selectable_sockets << @owner_pipe
				@selectable_sockets << @graceful_termination_pipe[0]
			end
			
			install_useful_signal_handlers
			socket_wrapper = Utils::UnseekableSocket.new
			channel        = MessageChannel.new
			buffer         = ''
			
			while true
				@iterations += 1
				if !accept_and_process_next_request(socket_wrapper, channel, buffer)
					break
				end
				@processed_requests += 1
			end
		rescue EOFError
			# Exit main loop.
		rescue Interrupt
			# Exit main loop.
		rescue SignalException => signal
			if signal.message != HARD_TERMINATION_SIGNAL &&
			   signal.message != SOFT_TERMINATION_SIGNAL
				raise
			end
		ensure
			revert_signal_handlers
			@main_loop_thread_lock.synchronize do
				@graceful_termination_pipe[1].close rescue nil
				@graceful_termination_pipe[0].close rescue nil
				@selectable_sockets = []
				@main_loop_generation += 1
				@main_loop_running = false
				@main_loop_thread_cond.broadcast
			end
		end
	end
	
	# Start the main loop in a new thread. This thread will be stopped by #cleanup.
	def start_main_loop_thread
		current_generation = @main_loop_generation
		@main_loop_thread = Thread.new do
			main_loop
		end
		@main_loop_thread_lock.synchronize do
			while @main_loop_generation == current_generation
				@main_loop_thread_cond.wait(@main_loop_thread_lock)
			end
		end
	end
	
	# Remove this request handler from the application pool so that no
	# new connections will come in. Then make the main loop quit a few
	# seconds after the last time a connection came in. This all is to
	# ensure that no connections come in while we're shutting down.
	#
	# May only be called while the main loop is running. May be called
	# from any thread.
	def soft_shutdown
		@select_timeout = @soft_termination_linger_time
		@graceful_termination_pipe[1].close rescue nil
		if @detach_key && @pool_account_username && @pool_account_password
			client = Utils::MessageClient.new(@pool_account_username, @pool_account_password)
			begin
				client.detach(@detach_key)
			ensure
				client.close
			end
		end
	end

private
	include Utils
	
	def should_use_unix_sockets?
		# Historical note:
		# There seems to be a bug in MacOS X Leopard w.r.t. Unix server
		# sockets file descriptors that are passed to another process.
		# Usually Unix server sockets work fine, but when they're passed
		# to another process, then clients that connect to the socket
		# can incorrectly determine that the client socket is closed,
		# even though that's not actually the case. More specifically:
		# recv()/read() calls on these client sockets can return 0 even
		# when we know EOF is not reached.
		#
		# The ApplicationPool infrastructure used to connect to a backend
		# process's Unix socket in the helper server process, and then
		# pass the connection file descriptor to the web server, which
		# triggers this kernel bug. We used to work around this by using
		# TCP sockets instead of Unix sockets; TCP sockets can still fail
		# with this fake-EOF bug once in a while, but not nearly as often
		# as with Unix sockets.
		#
		# This problem no longer applies today. The client socket is now
		# created directly in the web server, and the bug is no longer
		# triggered. Nevertheless, we keep this function intact so that
		# if something like this ever happens again, we know why, and we
		# can easily reactivate the workaround. Or maybe if we just need
		# TCP sockets for some other reason.
		
		#return RUBY_PLATFORM !~ /darwin/
		return true
	end

	def create_unix_socket_on_filesystem
		while true
			begin
				if defined?(NativeSupport)
					unix_path_max = NativeSupport::UNIX_PATH_MAX
				else
					unix_path_max = 100
				end
				socket_address = "#{passenger_tmpdir}/backends/ruby.#{generate_random_id(:base64)}"
				socket_address = socket_address.slice(0, unix_path_max - 1)
				socket = UNIXServer.new(socket_address)
				socket.listen(BACKLOG_SIZE)
				socket.close_on_exec!
				File.chmod(0666, socket_address)
				return [socket_address, socket]
			rescue Errno::EADDRINUSE
				# Do nothing, try again with another name.
			end
		end
	end
	
	def create_tcp_socket
		# We use "127.0.0.1" as address in order to force
		# TCPv4 instead of TCPv6.
		socket = TCPServer.new('127.0.0.1', 0)
		socket.listen(BACKLOG_SIZE)
		socket.close_on_exec!
		socket_address = "127.0.0.1:#{socket.addr[1]}"
		return [socket_address, socket]
	end

	# Reset signal handlers to their default handler, and install some
	# special handlers for a few signals. The previous signal handlers
	# will be put back by calling revert_signal_handlers.
	def reset_signal_handlers
		Signal.list_trappable.each_key do |signal|
			begin
				prev_handler = trap(signal, DEFAULT)
				if prev_handler != DEFAULT
					@previous_signal_handlers[signal] = prev_handler
				end
			rescue ArgumentError
				# Signal cannot be trapped; ignore it.
			end
		end
		trap('HUP', IGNORE)
	end
	
	def install_useful_signal_handlers
		trappable_signals = Signal.list_trappable
		
		trap(SOFT_TERMINATION_SIGNAL) do
			begin
				soft_shutdown
			rescue => e
				print_exception("Passenger RequestHandler soft shutdown routine", e)
			end
		end if trappable_signals.has_key?(SOFT_TERMINATION_SIGNAL.sub(/^SIG/, ''))
		
		trap('ABRT') do
			raise SignalException, "SIGABRT"
		end if trappable_signals.has_key?('ABRT')
		
		trap('QUIT') do
			@stderr.puts(global_backtrace_report)
			@stderr.flush
		end if trappable_signals.has_key?('QUIT')
	end
	
	def revert_signal_handlers
		@previous_signal_handlers.each_pair do |signal, handler|
			trap(signal, handler)
		end
	end
	
	def accept_and_process_next_request(socket_wrapper, channel, buffer)
		select_result = select(@selectable_sockets, nil, nil, @select_timeout)
		if select_result.nil?
			# This can only happen after we've received a soft termination
			# signal. No connection was accepted for @select_timeout seconds,
			# so now we quit the main loop.
			return false
		end
		
		ios = select_result.first
		if ios.include?(@main_socket)
			connection = socket_wrapper.wrap(@main_socket.accept)
			channel.io = connection
			headers, input_stream = parse_native_request(connection, channel, buffer)
			full_http_response = false
		elsif ios.include?(@http_socket)
			connection = socket_wrapper.wrap(@http_socket.accept)
			headers, input_stream = parse_http_request(connection)
			full_http_response = true
		else
			# The other end of the owner pipe has been closed, or the
			# graceful termination pipe has been closed. This is our
			# call to gracefully terminate (after having processed all
			# incoming requests).
			if @select_timeout
				# But if @select_timeout is set then it means that we
				# received a soft termination signal. In that case
				# we don't want to quit immediately, but @select_timeout
				# seconds after the last time a connection was accepted.
				#
				# #soft_shutdown not only closes the graceful termination
				# pipe, but it also tells the application pool to remove
				# this process from the pool, which will cause the owner
				# pipe to be closed. So we remove both IO objects
				# from @selectable_sockets in order to prevent the
				# next select call from immediately returning, allowing
				# it to time out.
				@selectable_sockets.delete(@graceful_termination_pipe[0])
				@selectable_sockets.delete(@owner_pipe)
				return true
			else
				return false
			end
		end
		
		if headers
			if headers[REQUEST_METHOD] == PING
				process_ping(headers, input_stream, connection)
			else
				process_request(headers, input_stream, connection, full_http_response)
			end
		end
		return true
	rescue => e
		if socket_wrapper.source_of_exception?(e)
			print_exception("Passenger RequestHandler's client socket", e)
		else
			raise
		end
	ensure
		# The 'close_write' here prevents forked child
		# processes from unintentionally keeping the
		# connection open.
		if connection && !connection.closed?
			begin
				connection.close_write
			rescue SystemCallError
			end
			begin
				connection.close
			rescue SystemCallError
			end
		end
		if input_stream && !input_stream.closed?
			input_stream.close rescue nil
		end
	end
	
	# Read the next request from the given socket, and return
	# a pair [headers, input_stream]. _headers_ is a Hash containing
	# the request headers, while _input_stream_ is an IO object for
	# reading HTTP POST data.
	#
	# Returns nil if end-of-stream was encountered.
	def parse_native_request(socket, channel, buffer)
		headers_data = channel.read_scalar(buffer, MAX_HEADER_SIZE)
		if headers_data.nil?
			return
		end
		headers = split_by_null_into_hash(headers_data)
		if @connect_password && headers[PASSENGER_CONNECT_PASSWORD] != @connect_password
			@stderr.puts "*** Passenger RequestHandler #{$$} warning: " <<
				"someone tried to connect with an invalid connect password."
			@stderr.flush
			return
		else
			return [headers, socket]
		end
	rescue SecurityError => e
		@stderr.puts("*** Passenger RequestHandler #{$$} warning: " <<
			"HTTP header size exceeded maximum.")
		@stderr.flush
		return nil
	end
	
	# Like parse_native_request, but parses an HTTP request. This is a very minimalistic
	# HTTP parser and is not intended to be complete, fast or secure, since the HTTP server
	# socket is intended to be used for debugging purposes only.
	def parse_http_request(socket)
		headers = {}
		
		data = ""
		while data !~ /\r\n\r\n/ && data.size < MAX_HEADER_SIZE
			data << socket.readpartial(16 * 1024)
		end
		if data.size >= MAX_HEADER_SIZE
			@stderr.puts("*** Passenger RequestHandler #{$$} warning: " <<
				"HTTP header size exceeded maximum.")
			@stderr.flush
			return nil
		end
		
		data.gsub!(/\r\n\r\n.*/, '')
		data.split("\r\n").each_with_index do |line, i|
			if i == 0
				# GET / HTTP/1.1
				line =~ /^([A-Za-z]+) (.+?) (HTTP\/\d\.\d)$/
				request_method = $1
				request_uri    = $2
				protocol       = $3
				path_info, query_string    = request_uri.split("?", 2)
				headers[REQUEST_METHOD]    = request_method
				headers["REQUEST_URI"]     = request_uri
				headers["QUERY_STRING"]    = query_string || ""
				headers["SCRIPT_NAME"]     = ""
				headers["PATH_INFO"]       = path_info
				headers["SERVER_NAME"]     = "127.0.0.1"
				headers["SERVER_PORT"]     = socket.addr[1].to_s
				headers["SERVER_PROTOCOL"] = protocol
			else
				header, value = line.split(/\s*:\s*/, 2)
				header.upcase!            # "Foo-Bar" => "FOO-BAR"
				header.gsub!("-", "_")    #           => "FOO_BAR"
				if header == "CONTENT_LENGTH" || header == "CONTENT_TYPE"
					headers[header] = value
				else
					headers["HTTP_#{header}"] = value
				end
			end
		end
		
		if @connect_password && headers["HTTP_X_PASSENGER_CONNECT_PASSWORD"] != @connect_password
			@stderr.puts "*** Passenger RequestHandler #{$$} warning: " <<
				"someone tried to connect with an invalid connect password."
			@stderr.flush
			return
		else
			return [headers, socket]
		end
	rescue EOFError
		return nil
	end
	
	def process_ping(env, input, output)
		output.write("pong")
	end
	
	# Generate a long, cryptographically secure random ID string, which
	# is also a valid filename.
	def generate_random_id(method)
		case method
		when :base64
			data = [File.read("/dev/urandom", 64)].pack('m')
			data.gsub!("\n", '')
			data.gsub!("+", '')
			data.gsub!("/", '')
			data.gsub!(/==$/, '')
		when :hex
			data = File.read("/dev/urandom", 64).unpack('H*')[0]
		end
		return data
	end
	
	def self.determine_passenger_header
		header = "Phusion Passenger (mod_rails/mod_rack) #{VERSION_STRING}"
		if File.exist?("#{File.dirname(__FILE__)}/../../enterprisey.txt") ||
		   File.exist?("/etc/passenger_enterprisey.txt")
			header << ", Enterprise Edition"
		end
		return header
	end

public
	PASSENGER_HEADER = determine_passenger_header
end

end # module PhusionPassenger
