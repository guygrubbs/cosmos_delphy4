#===============================================================================
# File: delphy_commands.rb
#
# Purpose:
#   Provides Ruby methods for COSMOS v4 to:
#     1) Connect to DELPHY (sends ID packet).
#     2) Build/send DELPHY packets (PKT_TYPE_SCRIPT, CONTROL, etc.).
#     3) Wait for ACK and COMPLETION telemetry with timeouts.
#     4) Offer high-level commands for inner/outer rotation, horizontal/vertical motion.
#
# Usage Example in a separate script (e.g., Script Runner):
#   require_relative '../lib/delphy_commands'
#
#   Delphy.connect_to_delphy(14)           # Connect & send ID = 14
#   Delphy.send_inner_rotation(45)         # 45-degree inner rotation
#   Delphy.send_outer_rotation(90)         # 90-degree outer rotation
#   Delphy.send_horizontal_motion(15)      # 15 mm horizontal
#   Delphy.send_vertical_motion(25)        # 25 mm vertical
#
# Dependencies:
#   - A 'DELPHY_INT' interface in target.txt with BINARY or RAW
#   - Telemetry defs (delphy_tlm.txt) for DELPHY_ACKNOWLEDGE, DELPHY_COMPLETION, etc.
#   - A custom decoder (delphy_decoder.rb) to parse inbound data
#===============================================================================

require 'cosmos'
require 'cosmos/script'
require 'cosmos/interfaces/interface'
require 'cosmos/logging/logger'

module Delphy
  #---------------------------------------------------------------------------
  # Packet Type Constants - matching your Python/GSEOS definitions
  #---------------------------------------------------------------------------
  PKT_TYPE_IDENTITY = 10
  PKT_TYPE_CONTROL  = 8
  PKT_TYPE_SCRIPT   = 6
  PKT_TYPE_MESSAGE  = 4
  PKT_TYPE_ACK      = 0
  PKT_TYPE_COMPLETE = 12

  #---------------------------------------------------------------------------
  # Status codes from Python script
  #---------------------------------------------------------------------------
  SUCCESSFUL = 0
  ABORTED    = 1
  EXCEPTION  = 2

  #---------------------------------------------------------------------------
  # Global Packet ID
  #   Mirrors the "session.packetID" usage in the Python script
  #---------------------------------------------------------------------------
  $delphy_packet_id = 1

  #---------------------------------------------------------------------------
  # Custom Timeout Exception
  #---------------------------------------------------------------------------
  class TimeoutError < StandardError; end

  #---------------------------------------------------------------------------
  # connect_to_delphy(machine_id = 14)
  #
  # 1) Connects the "DELPHY_INT" interface (if not already).
  # 2) Sends a PKT_TYPE_IDENTITY packet with the specified machine_id.
  # 3) Optionally waits for an ACK if your system sends one for identity.
  #---------------------------------------------------------------------------
  def self.connect_to_delphy(machine_id = 14)
    begin
      connect_interface('DELPHY_INT')
      Cosmos::Logger.info("DelphyCommands: Connected to DELPHY_INT interface.")
    rescue => e
      Cosmos::Logger.error("DelphyCommands: Failed to connect to DELPHY_INT - #{e.message}")
      message_box("Failed to connect to DELPHY_INT.\nError: #{e.message}", "Connection Error")
      return
    end

    # Build and send the identity packet
    begin
      machine_id_data = [machine_id].pack('N')  # 4-byte big-endian integer
      pkt = make_packet(PKT_TYPE_IDENTITY, machine_id_data)
      my_packet_id = $delphy_packet_id - 1  # ID used by this packet
      send_packet(pkt)

      Cosmos::Logger.info("DelphyCommands: Sent PKT_TYPE_IDENTITY with machine_id=#{machine_id}.")

      # If your system typically returns an ACK for ID, you can wait for it:
      # (Uncomment if needed.)
      # 
      # begin
      #   ack_code = wait_for_ack(my_packet_id, 5)  # 5-second timeout
      #   if ack_code != SUCCESSFUL
      #     Cosmos::Logger.error("DelphyCommands: ID packet ACK code indicates failure=#{ack_code}")
      #   else
      #     Cosmos::Logger.info("DelphyCommands: ID packet ACK success.")
      #   end
      # rescue TimeoutError => e
      #   Cosmos::Logger.error("DelphyCommands: Timeout waiting for ID ACK: #{e.message}")
      # end

    rescue => e
      Cosmos::Logger.error("DelphyCommands: Error sending PKT_TYPE_IDENTITY - #{e.message}")
      message_box("Error sending Identity packet.\n#{e.message}", "Connection Error")
    end
  end

  #---------------------------------------------------------------------------
  # make_packet(type, data_string = nil)
  #
  # Builds a raw binary DELPHY packet:
  #   [4 bytes: 0xDEADBEEF]
  #   [4 bytes: type]
  #   [4 bytes: packet ID from $delphy_packet_id]
  #   [8 bytes: session_time (double, big-endian)]
  #   [8 bytes: packet_time  (double, big-endian)]
  #   [4 bytes: length]
  #   [payload: data_string if length>0]
  #---------------------------------------------------------------------------
  def self.make_packet(type, data_string = nil)
    sync       = [0xDEADBEEF].pack('N')
    type_bytes = [type].pack('N')

    current_id = $delphy_packet_id
    $delphy_packet_id += 1
    id_bytes = [current_id].pack('N')

    # For simplicity, use Time.now.to_f for both session_time & packet_time
    session_time = Time.now.to_f
    packet_time  = Time.now.to_f

    session_time_bytes = [session_time].pack('G')  # 8-byte big-endian float
    packet_time_bytes  = [packet_time].pack('G')

    if data_string
      length_bytes = [data_string.bytesize].pack('N')
      payload      = data_string
    else
      length_bytes = [0].pack('N')
      payload      = ''
    end

    header = sync + type_bytes + id_bytes + session_time_bytes + packet_time_bytes + length_bytes
    packet = header + payload
    return packet
  end

  #---------------------------------------------------------------------------
  # send_packet(packet)
  #
  # Sends the raw bytes through the "DELPHY_INT" interface.
  #---------------------------------------------------------------------------
  def self.send_packet(packet)
    begin
      write_interface_data('DELPHY_INT', packet)
      Cosmos::Logger.info("DelphyCommands: Sent packet with size #{packet.size} bytes.")
    rescue => e
      Cosmos::Logger.error("DelphyCommands: Failed to send packet - #{e.message}")
    end
  end

  #---------------------------------------------------------------------------
  # wait_for_ack(expected_id, timeout=5)
  #
  # Waits until "DELPHY_ACKNOWLEDGE" telemetry has "ID" == expected_id,
  # or raises TimeoutError after 'timeout' seconds.
  # Returns ack_code if success.
  #---------------------------------------------------------------------------
  def self.wait_for_ack(expected_id, timeout=5)
    start_time = Time.now

    loop do
      ack_id   = tlm("DELPHY", "DELPHY_ACKNOWLEDGE", "ID")
      ack_code = tlm("DELPHY", "DELPHY_ACKNOWLEDGE", "Code")

      if ack_id == expected_id
        Cosmos::Logger.info("DelphyCommands: ACK for packet #{expected_id}, code=#{ack_code}")
        return ack_code
      end

      if (Time.now - start_time) > timeout
        msg = "Timeout waiting for ACK with ID=#{expected_id}"
        Cosmos::Logger.error("DelphyCommands: #{msg}")
        raise TimeoutError, msg
      end

      wait(0.25)
    end
  end

  #---------------------------------------------------------------------------
  # wait_for_completion(timeout=10)
  #
  # Waits for "DELPHY_COMPLETION" telemetry to show nonzero "Code",
  # or raises TimeoutError after 'timeout' seconds.
  # Returns comp_code if found.
  #---------------------------------------------------------------------------
  def self.wait_for_completion(timeout=10)
    start_time = Time.now

    loop do
      comp_code = tlm("DELPHY", "DELPHY_COMPLETION", "Code")
      if comp_code != 0
        Cosmos::Logger.info("DelphyCommands: COMPLETION code=#{comp_code}")
        return comp_code
      end

      if (Time.now - start_time) > timeout
        msg = "Timeout waiting for COMPLETION"
        Cosmos::Logger.error("DelphyCommands: #{msg}")
        raise TimeoutError, msg
      end

      wait(0.25)
    end
  end

  #---------------------------------------------------------------------------
  # Helper: send_script_command(script_name, parameter)
  #
  # 1) Build command string: "run(<script_name>(), <parameter>)"
  # 2) Make & send PKT_TYPE_SCRIPT
  # 3) Wait for ACK & COMPLETION
  #---------------------------------------------------------------------------
  def self.send_script_command(script_name, parameter)
    cmd_str = "run(#{script_name}(), #{parameter})"

    pkt = make_packet(PKT_TYPE_SCRIPT, cmd_str)
    my_packet_id = $delphy_packet_id - 1  # packet ID for this packet

    send_packet(pkt)

    # Wait for ACK
    begin
      ack_code = wait_for_ack(my_packet_id, 5)
      if ack_code != SUCCESSFUL
        Cosmos::Logger.error("DelphyCommands: Script '#{cmd_str}' => Non-successful ACK code=#{ack_code}")
        return
      end
    rescue TimeoutError => e
      Cosmos::Logger.error("DelphyCommands: Script '#{cmd_str}' => Timeout waiting for ACK. #{e.message}")
      return
    end

    # Wait for COMPLETION
    begin
      comp_code = wait_for_completion(10)
      if comp_code == SUCCESSFUL
        Cosmos::Logger.info("DelphyCommands: Script '#{cmd_str}' => COMPLETED successfully.")
      else
        Cosmos::Logger.error("DelphyCommands: Script '#{cmd_str}' => COMPLETED with code=#{comp_code}.")
      end
    rescue TimeoutError => e
      Cosmos::Logger.error("DelphyCommands: Script '#{cmd_str}' => Timeout waiting for COMPLETION. #{e.message}")
    end
  end

  #---------------------------------------------------------------------------
  # Command #1: send_inner_rotation
  #   e.g. Delphy.send_inner_rotation(45)
  #---------------------------------------------------------------------------
  def self.send_inner_rotation(angle_degrees)
    send_script_command("inner_rotation_script", angle_degrees)
  end

  #---------------------------------------------------------------------------
  # Command #2: send_outer_rotation
  #   e.g. Delphy.send_outer_rotation(90)
  #---------------------------------------------------------------------------
  def self.send_outer_rotation(angle_degrees)
    send_script_command("outer_rotation_script", angle_degrees)
  end

  #---------------------------------------------------------------------------
  # Command #3: send_horizontal_motion
  #   e.g. Delphy.send_horizontal_motion(15)
  #---------------------------------------------------------------------------
  def self.send_horizontal_motion(distance_mm)
    send_script_command("horizontal_motion_script", distance_mm)
  end

  #---------------------------------------------------------------------------
  # Command #4: send_vertical_motion
  #   e.g. Delphy.send_vertical_motion(25)
  #---------------------------------------------------------------------------
  def self.send_vertical_motion(distance_mm)
    send_script_command("vertical_motion_script", distance_mm)
  end

end
