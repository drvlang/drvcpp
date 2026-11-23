project('drvlang-members', 'cpp')
fs = import('fs')
subdir('pkg')
foreach member : ['api', 'worker']
  if fs.is_dir('apps' / member)
    subdir('apps' / member)
  endif
endforeach
