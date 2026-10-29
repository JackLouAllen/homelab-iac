# Apply settings given as JSON in GITLAB_SETTINGS to the instance's application settings. Prints
# "changed: a, b" if it changed anything and "unchanged" if not, so Ansible can report it.
wanted = JSON.parse(ENV.fetch('GITLAB_SETTINGS'))
settings = ApplicationSetting.current
settings.assign_attributes(wanted)
changed = settings.changed
if changed.empty?
  puts 'unchanged'
else
  settings.save!
  puts "changed: #{changed.join(', ')}"
end
