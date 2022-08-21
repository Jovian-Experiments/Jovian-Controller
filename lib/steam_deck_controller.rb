require "hexdump"
require "libusb"

class SteamDeckController
  VERBOSE = !!ENV["VERBOSE"]

  module MessageTypes
    STATE = 0x01
    SERIAL = 0xAE
    IDENTIFICATION = 0x83
    CONFIGURE = 0x87
    HAPTIC_FEEDBACK = 0x8F
    DISABLE_LIZARD_MODE = 0x81
    ENABLE_LIZARD_BUTTONS = 0x85
    ENABLE_LIZARD_MOUSE = 0x8E
    UNKNOWN_C5 = 0xC5
  end

  # Without the message type and the length
  MESSAGE_FORMAT = {
    MessageTypes::STATE => "C1",
    MessageTypes::SERIAL => "C1",
    MessageTypes::HAPTIC_FEEDBACK => "CS<S<S<C",
    MessageTypes::UNKNOWN_C5 => "CCC", # Always ffffff
  }
  REPLY_FORMAT = {
    MessageTypes::SERIAL => "CZ60",
    MessageTypes::IDENTIFICATION => [
      # XXX might not map the same on the steam deck
      # https://gitlab.com/dennis-hamester/scraw/blob/master/scraw/packets.h#L130
      # 00000000  83 37 01 05 12 00 00 02 00 00 00 00 0a 7a fb 12  |.7...........z..|
      # 00000010  61 04 44 96 0d 62 09 1b 00 00 00 0b a0 0f 00 00  |a.D..b..........|
      # 00000020  10 03 00 00 00 0d 7a fb 12 61 0c 44 96 0d 62 0e  |......z..a.D..b.|
      # 00000030  1b 00 00 00 11 03 00 00 00 00 00 00 00 00 00 00  |................|
      "x6",
      "S<", # product
      "x8",
      "Q<", # bootloader ts?
      "x",
      "Q<", # firmware ts?
      "x",
      "Q<", # radio ts?
      "x5",
    ].join(""),
  }

  module StateTypes
    DECK = 0x09
  end

  # Without the static preamble
  STATE_FORMAT = {
    # [B] pressed
    # 00000000  01 00 09 40 43 bf 09 00 20 00 00 00 00 00 00 00  |...@C... .......|
    #           ¯¯¯¯¯ [ id] [monotonic] [¯¯¯¯¯¯ buttons¯¯¯¯¯¯¯]
    # 00000010  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
    #           [ L tpad  ] [ R tpad  ]
    # 00000020  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
    #                                               [Ltg] [Rtg]
    # 00000030  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  |................|
    #           [ L joy   ] [ R joy   ]             LJ    RJ     LJ/RJ: touching joystick
    # 00000040

    StateTypes::DECK => [
      # 0x00

      # Implicitly skipped by the basic parsing of the message.

      # 0x02

      "L<", # monotonically increasing; 8 bits "0xff divisions of a second", followed by seconds?
      "Q<", # Buttons (and other button~y events)

      # 0x10

      "s<", # left touchpad X (right positive)
      "s<", # left touchpad Y (top positive)

      "s<", # right touchpad X (right positive)
      "s<", # right touchpad Y (top positive)

      "x8", # All zeroes when unconfigured

      # 0x20

      "x12", # All zeroes when unconfigured

      "s<", # Left trigger
      "s<", # Right trigger

      # 0x30

      "s<", # left joystick x (right positive)
      "s<", # left joystick y (top positive)
      "s<", # right joystick x (right positive)
      "s<", # right joystick y (top positive)

      "x4", # nothing?

      # Data for joystick touch seems noisy
      "cx", # Left joystick touch (last byte goes to ff spuriously in pair with previous byte)
      "cx", # Right joystick touch (same)

    ].join("")
  }

  # Buttons, in order from the StateTypes::DECK message buttons data
  BUTTONS = [
    :TRIGGER_RIGHT,
    :TRIGGER_LEFT,
    :SHOULDER_RIGHT,
    :SHOULDER_LEFT,
    :BUTTON_Y,
    :BUTTON_B,
    :BUTTON_X,
    :BUTTON_A,
    :BUTTON_UP,
    :BUTTON_RIGHT,
    :BUTTON_LEFT,
    :BUTTON_DOWN,
    :BUTTON_BACK, # alt-tab-ish?
    :BUTTON_STEAM,
    :BUTTON_START,
    :BUTTON_L5,
    :BUTTON_R5,
    :TOUCHPAD_LEFT_PRESS,
    :TOUCHPAD_RIGHT_PRESS,
    :TOUCHPAD_LEFT_TOUCH,
    :TOUCHPAD_RIGHT_TOUCH,
    :_UNUSED__1, # unused
    :JOYSTICK_LEFT_PRESS,
    :_UNUSED__2, # unused
    :_UNUSED__3, # unused
    :_UNUSED__4, # unused
    :JOYSTICK_RIGHT_PRESS,
    :_UNUSED__5, # unused
    :_UNUSED__6, # unused
    :_UNUSED__7, # unused
    :_UNUSED__8, # unused
    :_UNUSED__9, # unused
    :_UNUSED__10, # unused
    :_UNUSED__11, # unused
    :_UNUSED__12, # unused
    :_UNUSED__13, # unused
    :_UNUSED__14, # unused
    :_UNUSED__15, # unused
    :_UNUSED__16, # unused
    :_UNUSED__17, # unused
    :_UNUSED__18, # unused
    :BUTTON_L4,
    :BUTTON_R4,
    :_UNUSED__19, # unused
    :_UNUSED__20, # unused
    :_UNUSED__21, # unused
    :JOYSTICK_LEFT_TOUCH,
    :JOYSTICK_RIGHT_TOUCH,
    :_UNUSED__22, # unused
    :_UNUSED__22, # unused
    :BUTTON_QUICK_MENU, # ...
  ]

  LIZARD_BUTTON_INTERFACE = 0x00
  LIZARD_MOUSE_INTERFACE  = 0x01
  CONTROL_INTERFACE = 0x02
  STATE_ENDPOINT = 0x03

  ENDPOINT_DIRECTION_IN = 0x80
  ENDPOINT_DIRECTION_OUT = 0x00
  GET_REPORT = 0x01
  SET_REPORT = 0x09

  def initialize()
    @usb = LIBUSB::Context.new
    @device = @usb.devices(idVendor: 0x28de, idProduct: 0x1205).first
    @handle = @device.open()
    @handle.auto_detach_kernel_driver = true
    [
      CONTROL_INTERFACE,
      LIZARD_MOUSE_INTERFACE,
      LIZARD_BUTTON_INTERFACE,
    ].each do |interface|
      @handle.claim_interface(interface)
    end
  end

  def detach_from_kernel_driver()
    [
      CONTROL_INTERFACE,
      LIZARD_MOUSE_INTERFACE,
      LIZARD_BUTTON_INTERFACE,
    ].each do |interface|
      if @handle.kernel_driver_active?(interface)
        puts "[!] Detaching kernel driver for interface #{interface}"
        @handle.detach_kernel_driver(interface)
        # Just in case
        disable_lizard_mode()
      end
    end
  end

  def set_report(data)
    @handle.control_transfer(
      bmRequestType: 0x21,
      bRequest: SET_REPORT,
      wValue: 0x0300,
      wIndex: 0x0002,
      dataOut: data,
    )
  end

  def get_report(length)
    @handle.control_transfer(
      bmRequestType: 0xa1,
      bRequest: GET_REPORT,
      wValue: 0x0300,
      wIndex: 0x0002,
      dataIn: length,
    )
  end

  def send_message(type, *payload)
    format = MESSAGE_FORMAT[type]
    format ||= ""
    length = payload.pack(format).length
    padding = 64 - length - 2
    data = [
      type, length, *payload,
      # Padding for `#pack`ing
      *(padding.times.map { 0x00 })
    ]
    format = "CC#{format}"
    if padding > 0 then
      format = "#{format}C#{padding}"
    end
    data = data.pack(format)

    if VERBOSE
      puts "====>"
      data.hexdump
    end

    set_report(data)

    reply = get_report(64)
    if VERBOSE
      puts "<===="
      reply.hexdump
    end

    format = REPLY_FORMAT[type]
    format ||= ""
    reply = reply.unpack("CC#{format}")

    raise "Unexpected reply (#{reply.first}), expecting type '#{type}'" unless reply.first == type

    reply.shift # Drop the message type
    reply.shift # Drop the length
    reply
  end

  def get_serial(id)
    send_message(MessageTypes::SERIAL, id).last
  end

  def identification()
    send_message(MessageTypes::IDENTIFICATION)
  end

  def disable_lizard_mode()
    send_message(MessageTypes::DISABLE_LIZARD_MODE)
  end

  def enable_lizard_mode()
    send_message(MessageTypes::ENABLE_LIZARD_BUTTONS)
    send_message(MessageTypes::ENABLE_LIZARD_MOUSE)
    nil
  end

  def haptic(side, amplitude, period, count)
    send_message(
      MessageTypes::HAPTIC_FEEDBACK,
      side, amplitude, period, count,
      0x00
    )
  end

  def get_state()
    data  = @handle.interrupt_transfer(
      endpoint: ENDPOINT_DIRECTION_IN | SteamDeckController::STATE_ENDPOINT,
      dataIn: 64,
    )
    if VERBOSE
      puts "\n[ state reports ]"
      data.hexdump(repeating: true)
      puts
    end
    # https://dennis-hamester.gitlab.io/scraw/protocol/#sec-8-1
    message_type, state_type, size = data.unpack("CxCC")
    raise "Unexpected state report, message type #{message_type}" unless message_type == MessageTypes::STATE

    type_format = STATE_FORMAT[state_type]
    raise "Unexpected state type #{state_type}" unless type_format

    data = data.unpack("xxxx#{type_format}")
    monotonic = data.shift
    buttons_data = data.shift

    touchpads = {
      left: {
        x: data.shift,
        y: data.shift,
      },
      right: {
        x: data.shift,
        y: data.shift,
      },
    }

    triggers = {
      left: data.shift,
      right: data.shift,
    }

    joysticks = {
      left: {
        x: data.shift,
        y: data.shift,
      },
      right: {
        x: data.shift,
        y: data.shift,
      },
    }

    joysticks[:left][:touch] = data.shift;
    joysticks[:right][:touch] = data.shift;

    if VERBOSE
      puts "monotonic: " + monotonic.to_s(16)
      puts "buttons:   " + buttons_data.to_s(2).rjust(64, "0")
    end

    buttons_state = (BUTTONS.length).times.map do |i|
      [BUTTONS[i], (buttons_data & (1<<i)) != 0]
    end.filter{|k,v| k && !k.match(/^_/)}.to_h

    {
      buttons_state: buttons_state,
      triggers: triggers,
      joysticks: joysticks,
      touchpads: touchpads,
    }
  end
end
