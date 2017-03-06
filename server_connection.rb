require 'socket'
require 'ipaddr'
require 'openssl'
require_relative('destination_connection')

# The ServerConnection class deals with all communication with the Deploy server
class ServerConnection
  class ServerDisconnected < StandardError;end
  attr_reader :destination_connections
  attr_writer :nio_monitor

  # Create a secure TLS connection to the Deploy server
  def initialize(server_host, nio_selector, check_certificate=true)
    puts "Attempting to connect to #{server_host}"
    @destination_connections = {}
    @nio_selector = nio_selector

    # Create a TCP socket to the Deploy server
    @tcp_socket = TCPSocket.new(server_host, 7777)

    # Configure an OpenSSL context with server vertification
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.verify_mode = OpenSSL::SSL::VERIFY_PEER
    # Load the agent certificate and key used to authenticate this agent
    ctx.cert = OpenSSL::X509::Certificate.new(File.read(Agent::CERTIFICATE_PATH))
    ctx.key = OpenSSL::PKey::RSA.new(File.read(Agent::KEY_PATH))
    # Load the Deploy CA used to verify the server
    ctx.ca_file = Agent::CA_PATH

    # Create the secure connection
    @socket = OpenSSL::SSL::SSLSocket.new(@tcp_socket, ctx)
    @socket.connect
    # Check the remote certificate
    @socket.post_connection_check(server_host) if check_certificate
    # Create send and receive buffers
    @tx_buffer = String.new.force_encoding('BINARY')
    @rx_buffer = String.new.force_encoding('BINARY')

    @nio_monitor = @nio_selector.register(@tcp_socket, :r)
    @nio_monitor.value = self

    puts "Successfully connected to server"
  rescue => e
    puts "Something went wrong connecting to server."
    puts "Retrying in 10 seconds."
    sleep 10
    retry
  end

  # Receive and process packets from the control server
  def rx_data
    # Ensure all received data is read
    @rx_buffer << @socket.readpartial(10240)
    while(@socket.pending > 0)
      @rx_buffer << @socket.readpartial(10240)
    end
    # Wait until we have a complete packet of data
    while @rx_buffer.bytesize >=2 && @rx_buffer.bytesize >= @rx_buffer[0,2].unpack('n')[0]
      length = @rx_buffer.slice!(0,2).unpack('n')[0]
      # Extract the packet from the buffered stream
      packet = @rx_buffer.slice!(0,length-2)
      # Check what type of packet we have received
      case packet.bytes[0]
      when 1
        # Process new connection request
        id = packet[1,2].unpack('n')[0]
        host, port = packet[3..-1].split('/', 2)
        puts "[#{id}] Connect Request from server: #{host}:#{port}"
        begin
          # Create conenction to the final destination and save info by id
          @destination_connections[id] = DestinationConnection.new(host, port, id, @nio_selector, self)
        rescue => e
          # Something went wrong, inform the Deploy server
          puts "An error occurred: #{e.message}"
          puts e.backtrace
          send_connection_error(id, e.message)
        end
      when 3
        # Process a connection close request
        id = packet[1,2].unpack('n')[0]
        if @destination_connections[id]
          puts "[#{id}] Close requested by server, closing"
          @destination_connections[id].close
        else
          puts "[#{id}] Close requested by server, not open"
        end
      when 4
        # Data incoming, send it to the backend
        id = packet[1,2].unpack('n')[0]
        puts "[#{id}] Data received from server"
        @destination_connections[id].send_data(packet[3..-1])
      end
    end
  rescue EOFError, Errno::ECONNRESET
    close
  end

  # Notify server of successful connection
  def send_connection_success(id)
    send_packet([2, id, 0].pack('CnC'))
  end

  # Notify server of failed connection
  def send_connection_error(id, reason)
    send_packet([2, id, 1, reason].pack('CnCa*'))
  end

  # Notify server of closed connection
  def send_connection_close(id)
    send_packet([3, id].pack('Cn'))
  end

  # Proxy data (coming from the backend) to the Deploy server
  def send_data(id, data)
    send_packet([4, id, data].pack('Cna*'))
  end

  # Called by event loop to send all waiting packets to the Deploy server
  def tx_data
    bytes_sent = @socket.write_nonblock(@tx_buffer[0,1024])
    # Send as much data as possible
    if bytes_sent >= @tx_buffer.bytesize
      @tx_buffer = String.new.force_encoding('BINARY')
      @nio_monitor.interests = :r
    else
      # If we didn't manage to send all the data, leave
      # the remaining data in the send buffer
      @tx_buffer.slice!(0, bytes_sent)
    end
  rescue EOFError, Errno::ECONNRESET
    close
  end

  private

  def close
    puts "Server disconnected, terminating all connections"
    @destination_connections.values.each{ |s| s.close }
    @nio_selector.deregister(@tcp_socket)
    @socket.close
    @tcp_socket.close
    raise ServerDisconnected
  end

  # Queue a packet of data to be sent to the Deploy server
  def send_packet(data)
    @tx_buffer << [data.bytesize+2, data].pack('na*')
    @nio_monitor.interests = :rw
  end

end
