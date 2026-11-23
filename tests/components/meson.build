project('component-consumer', 'c')
greeting = dependency('greeting', fallback: ['greeting', 'greeting_dep'])
client = executable('client', 'main.c', dependencies: greeting, install: true)
test('client', client)
