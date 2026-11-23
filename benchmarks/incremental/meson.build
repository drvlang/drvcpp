project('codec-client', 'cpp')
codec = dependency('openh264', fallback: ['openh264', 'openh264_dep'],
                   default_options: ['tests=disabled'])
client = executable('codec-client', 'check.cpp', dependencies: codec, install: true)
test('initialize encoder', client)
