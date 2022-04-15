require_relative "lib/steam_deck_controller"
require "uinput/device"

module Uinput
  class Device
    class Initializer
      def add_axis(axis, min, max)
        code = (axis.is_a? Symbol) ? LinuxInput.const_get(axis) : axis
        setup = UinputAbsSetup.new()
        setup[:code] = code
        setup[:absinfo][:value] = 0
        setup[:absinfo][:minimum] = min
        setup[:absinfo][:maximum] = max
        setup[:absinfo][:fuzz] = 0
        setup[:absinfo][:flat] = 0
        setup[:absinfo][:resolution] = 4
        @file.ioctl(UI_SET_ABSBIT, code)
        @file.ioctl(UI_ABS_SETUP, setup.pointer.read_bytes(setup.size))
      end
    end
  end
end

AXIS_MAX = 0xffff/2

DPAD_IS_HAT = true

# Amount to sleep between updates.
# (Is there something better to do here? It updates too frequently imo, and burns CPU)
SLEEP_AMOUNT = 0.015

# The backoff algorithm is jank... at best...
# But with these settings, it takes a full 5 seconds before the backoff starts
# kicking-in and slowly decays perfs until checks happen at a rhythm of 1s
# between each.
#
# It takes 1 minute 10 seconds before we reach *0.05*s between checks, which is
# still quite fast to check. It takes 4 minutes 25 seconds before we reach
# *0.1s* between checks, which is still quite fast. Using an actual maths
# function instead of simply increasing sleep linearly might give better
# results in the end, but CPU load is demonstrably lower.
#
# The longer we wait between checks, the less there is a burden on the CPU of
# an idle steamdeck, and thus its battery while idle.

# 100 * 0.01 == 1s
BACKOFF = 100
# Make backoff increase slower by this factor
BACKOFF_FACTOR = 500
MAX_BACKOFF = BACKOFF * BACKOFF_FACTOR

# After a suspend cycle, how long the controller may be "stuck" in lizard
# mode...
REFRESH_FREQUENCY = (5/SLEEP_AMOUNT).to_i

BUTTONS_MAPPING = {
  # Tip: mapping follows roughly `linux:drivers/input/joystick/xpad.c`

  BUTTON_A: :BTN_A,
  BUTTON_B: :BTN_B,
  BUTTON_X: :BTN_X,
  BUTTON_Y: :BTN_Y,

  BUTTON_START: :BTN_START,
  BUTTON_BACK: :BTN_SELECT,
  BUTTON_STEAM: :BTN_MODE,

  JOYSTICK_LEFT_PRESS: :BTN_THUMBL,
  JOYSTICK_RIGHT_PRESS: :BTN_THUMBR,

  SHOULDER_LEFT: :BTN_TL,
  SHOULDER_RIGHT: :BTN_TR,
  TRIGGER_LEFT: :BTN_TL2,
  TRIGGER_RIGHT: :BTN_TR2,

  # Buttons that won't map like xpad
  BUTTON_QUICK_MENU: :BTN_BASE,
  BUTTON_L4: :BTN_C,
  BUTTON_R4: :BTN_Z,
  BUTTON_L5: :BTN_GEAR_DOWN,
  BUTTON_R5: :BTN_GEAR_UP,
}

unless DPAD_IS_HAT
  BUTTONS_MAPPING[:BUTTON_UP] = :BTN_TRIGGER_HAPPY3
  BUTTONS_MAPPING[:BUTTON_LEFT] = :BTN_TRIGGER_HAPPY1
  BUTTONS_MAPPING[:BUTTON_RIGHT] = :BTN_TRIGGER_HAPPY2
  BUTTONS_MAPPING[:BUTTON_DOWN] = :BTN_TRIGGER_HAPPY4
end

AXES_MAPPING = {
  # left stick
  ABS_X: [:joysticks, :left, :x],
  ABS_Y: [:joysticks, :left, :y],
  # right stick
  ABS_RX: [:joysticks, :right, :x],
  ABS_RY: [:joysticks, :right, :y],
  # triggers
  ABS_Z:  [:triggers, :left],
  ABS_RZ: [:triggers, :right],
}

if DPAD_IS_HAT
  # d-pad axes
  AXES_MAPPING[:ABS_HAT0X] = "DPADX"
  AXES_MAPPING[:ABS_HAT0Y] = "DPADY"
end

virtual = Uinput::Device.new do
  self.name = "Jovian Controller"
  self.type = LinuxInput::BUS_VIRTUAL
  BUTTONS_MAPPING.each do |_, btn|
    self.add_button(btn)
  end
  AXES_MAPPING.each do |axis, _|
    self.add_axis(axis, AXIS_MAX * -1, AXIS_MAX)
  end
  self.add_event(:EV_KEY)
  self.add_event(:EV_ABS)
  self.add_event(:EV_SYN)
end

puts "Adding `#{virtual.name}` device..."

SteamDeckController.new.tap do |controller|
  puts "Serial: #{controller.get_serial(0x01)}"

  # Resetting haptics
  controller.haptic(0, 0, 0, 0)
  controller.haptic(1, 0, 0, 0)

  # Turning lizard mode on and off again...
  controller.enable_lizard_mode()
  controller.disable_lizard_mode()

  backoff = 0
  counter = REFRESH_FREQUENCY
  loop do
    any_held = false
    state = controller.get_state
    BUTTONS_MAPPING.each do |sd, virt|
      value = state[:buttons_state][sd] ? 1 : 0
      any_held = true if value != 0
      virtual.send_event(:EV_KEY, virt, value)
      virtual.send_event(:EV_SYN, :SYN_REPORT)
    end
    AXES_MAPPING.each do |virt, sd|
      value = 
      if sd.is_a?(String) then
        value =
          if sd == "DPADY"
            if state[:buttons_state][:BUTTON_UP]
              AXIS_MAX * -1
            elsif state[:buttons_state][:BUTTON_DOWN]
              AXIS_MAX
            else
              0
            end
          else
            if state[:buttons_state][:BUTTON_LEFT]
              AXIS_MAX * -1
            elsif state[:buttons_state][:BUTTON_RIGHT]
              AXIS_MAX
            else
              0
            end
          end
        any_held = true if value > 0
        virtual.send_event(:EV_ABS, virt, value)
      else
        value = (state.dig(*sd) / (0xffff*1.0) * AXIS_MAX*2).to_i
        value *= -1 if sd.last == :y
        any_held = true if value > 0
        virtual.send_event(:EV_ABS, virt, value)
      end
    end

    # Periodically refreshes kernel driver state.
    if counter == 0 then
      controller.detach_from_kernel_driver
      counter = REFRESH_FREQUENCY
    else
      counter -= 1
    end
    if any_held
      backoff = 1
    else
      backoff += 1 if backoff < MAX_BACKOFF
    end
    sleep_for = SLEEP_AMOUNT * backoff / BACKOFF_FACTOR
    sleep_for = SLEEP_AMOUNT if sleep_for < SLEEP_AMOUNT
    sleep sleep_for
  end
end
