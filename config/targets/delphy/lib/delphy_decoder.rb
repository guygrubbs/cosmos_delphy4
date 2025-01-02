require 'cosmos'
require 'cosmos/packets/packet'

module Delphy
  class Decoder
    # Packet Types (from your Python script)
    PKT_TYPE_MESSAGE  = 4
    PKT_TYPE_ACK      = 0
    PKT_TYPE_COMPLETE = 12

    def initialize
      # Buffer for accumulating raw bytes
      @buffer = []
    end

    #
    # process_data(data):
    #   Invoked automatically by COSMOS each time new data arrives on the interface.
    #
    def process_data(data)
      # Convert incoming string data to an array of bytes and store
      @buffer.concat(data.bytes)

      # Repeatedly parse out packets (if any) from the buffer
      packet = parse_pcs_stream(@buffer)
      while packet
        route_packet(packet)
        packet = parse_pcs_stream(@buffer)
      end
    end

    private

    #
    # parse_pcs_stream(buffer):
    #   Scans for the 0xDEADBEEF sync word, checks header sizes, extracts payload.
    #   Returns a hash-like 'packet' object or nil if insufficient data is available.
    #
    def parse_pcs_stream(buffer)
      MIN_HEADER_SIZE = 32  # 4 + 4 + 4 + 8 + 8 + 4

      # If we don't have enough bytes to check the header, return nil
      return nil if buffer.size < MIN_HEADER_SIZE

      # Search for the sync word 0xDEADBEEF (as a 4-byte big-endian integer)
      sync_word = 0xDEADBEEF
      # We'll look at the integer formed by the first 4 bytes. If it doesn't match,
      # we discard bytes until we find the sync.
      # A more efficient approach uses buffer.index(), but here's a manual approach:

      idx = 0
      while idx <= buffer.size - 4
        candidate = (buffer[idx] << 24) + (buffer[idx+1] << 16) + (buffer[idx+2] << 8) + buffer[idx+3]
        if candidate == sync_word
          # Found the sync at index idx
          break
        else
          idx += 1
        end
      end

      # If we didn't find the sync in the entire buffer
      if idx > buffer.size - 4
        # Not enough data or no sync found -> can't form a packet
        return nil
      end

      # Now check if we have at least a full header from idx
      # We need 32 bytes (sync + type + id + sessionTime + packetTime + length).
      if (buffer.size - idx) < MIN_HEADER_SIZE
        # Not enough data yet to parse a complete header
        return nil
      end

      # Extract fields from the header (assuming big-endian)
      sync_bytes = buffer[idx, 4]    # Not strictly needed besides validation
      type_bytes = buffer[idx+4, 4]
      id_bytes   = buffer[idx+8, 4]
      sess_bytes = buffer[idx+12, 8]
      pkt_bytes  = buffer[idx+20, 8]
      len_bytes  = buffer[idx+28, 4]

      # Convert them to integers/floats
      # For big-endian 4-byte int: unpack("N")
      # For big-endian 8-byte float: unpack("G")
      pkt_type = type_bytes.pack('C*').unpack('N')[0]
      pkt_id   = id_bytes.pack('C*').unpack('N')[0]
      session_time = sess_bytes.pack('C*').unpack('G')[0]
      packet_time  = pkt_bytes.pack('C*').unpack('G')[0]
      data_len = len_bytes.pack('C*').unpack('N')[0]

      # Check if we have enough data for the payload
      total_needed = MIN_HEADER_SIZE + data_len
      if (buffer.size - idx) < total_needed
        # Not enough data for the full payload
        return nil
      end

      # Everything is present: extract payload
      data_start = idx + MIN_HEADER_SIZE
      data_end   = data_start + data_len
      payload    = buffer[data_start...data_end]

      # Build a packet structure (hash)
      parsed_packet = {
        type:         pkt_type,
        id:           pkt_id,
        session_time: session_time,
        packet_time:  packet_time,
        length:       data_len,
        payload:      payload
      }

      # Now remove these bytes from the buffer
      buffer.shift(data_end)  # remove everything up to data_end

      return parsed_packet
    end

    #
    # route_packet(packet):
    #   Based on the type field, populates one of:
    #   - DELPHY_MESSAGE
    #   - DELPHY_ACKNOWLEDGE
    #   - DELPHY_COMPLETION
    #
    #   and sends it to COSMOS.
    #
    def route_packet(packet)
      case packet[:type]
      when PKT_TYPE_MESSAGE
        process_message(packet)
      when PKT_TYPE_ACK
        process_acknowledge(packet)
      when PKT_TYPE_COMPLETE
        process_completion(packet)
      else
        # For now, ignore or log unknown packet types
        Cosmos::Logger.warn("DelphyDecoder: Unknown packet type #{packet[:type]}")
      end
    end

    #
    # process_message(packet)
    #   The payload for PKT_TYPE_MESSAGE in the Python script:
    #       first 4 bytes = level (uint32)
    #       next 4 bytes = msglen (uint32)
    #       rest = message text
    #
    def process_message(packet)
      data = packet[:payload]

      # Extract level (4 bytes) and msg_len (4 bytes)
      level_bytes = data[0, 4]
      msglen_bytes = data[4, 4]

      level   = level_bytes.pack('C*').unpack('N')[0]
      msg_len = msglen_bytes.pack('C*').unpack('N')[0]

      # The remaining bytes after the first 8 are the actual message
      msg = data[8...data.size]

      # Convert to a string, removing trailing nulls if present
      msg_str = msg.pack('C*').delete("\x00")

      # Publish the telemetry packet to COSMOS
      # This populates the items in DELPHY_MESSAGE from delphy_tlm.txt
      publish_packet('DELPHY', 'DELPHY_MESSAGE') do |p|
        p.write('LEVEL', level)
        p.write('LEN',   msg_len)
        p.write('MESSAGE', msg_str)
      end
    end

    #
    # process_acknowledge(packet)
    #   The payload for PKT_TYPE_ACK in Python:
    #       first 4 bytes = ACK packet ID
    #       next 4 bytes = code
    #       next 4 bytes = msglen
    #       rest = ack text
    #
    def process_acknowledge(packet)
      data = packet[:payload]

      id_bytes     = data[0,4]
      code_bytes   = data[4,4]
      msglen_bytes = data[8,4]

      ack_id   = id_bytes.pack('C*').unpack('N')[0]
      ack_code = code_bytes.pack('C*').unpack('N')[0]
      msg_len  = msglen_bytes.pack('C*').unpack('N')[0]

      msg = data[12...data.size]
      msg_str = msg.pack('C*').delete("\x00")

      publish_packet('DELPHY', 'DELPHY_ACKNOWLEDGE') do |p|
        p.write('ID',      ack_id)
        p.write('Code',    ack_code)
        p.write('LEN',     msg_len)
        p.write('MESSAGE', msg_str)
      end
    end

    #
    # process_completion(packet)
    #   The payload for PKT_TYPE_COMPLETE in Python:
    #       first 4 bytes = code
    #       next 4 bytes = msglen
    #       rest = completion text
    #
    def process_completion(packet)
      data = packet[:payload]

      code_bytes   = data[0,4]
      msglen_bytes = data[4,4]

      comp_code = code_bytes.pack('C*').unpack('N')[0]
      msg_len   = msglen_bytes.pack('C*').unpack('N')[0]

      msg = data[8...data.size]
      msg_str = msg.pack('C*').delete("\x00")

      publish_packet('DELPHY', 'DELPHY_COMPLETION') do |p|
        p.write('Code',    comp_code)
        p.write('LEN',     msg_len)
        p.write('MESSAGE', msg_str)
      end
    end

    #
    # publish_packet(target_name, packet_name)
    #   Creates a new telemetry packet instance with the given target/packet name and yields it to the block.
    #   This is a typical COSMOS v4 approach for user-data routers.
    #
    def publish_packet(target_name, packet_name)
      pkt = Cosmos::Packet.new(nil, target_name, packet_name, nil)
      yield pkt if block_given?
      # Mark the packet as complete and send it into COSMOS
      pkt.write('ID_ITEM', 0)  # Must write an ID if needed, else 0
      pkt.buffer_type = :PRIMARY # Mark as a primary packet for proper logging
      Cosmos::PacketLog.write_packet(pkt)
      Cosmos::PacketTelemetryServer.publish_packet(pkt)
    end
  end
end
