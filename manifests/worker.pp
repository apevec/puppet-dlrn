# == Class: delorean::worker
#
#  This class sets up a Delorean worker
#
# === Parameters:
#
# [*distro*]
#   (required) Distro for worker (f22, centos7...)
#
# [*target*]
#   (required) Mock target (fedora, centos, fedora-rawhide, centos-liberty...)
#
# [*distgit_branch*]
#   (optional) Branch for dist-git
#   Defaults to rpm-master
#
# [*distro_branch*]
#   (optional) Branch for upstream git
#   Defaults to master
#
# [*uid*]
#   (optional) uid for user
#   Defaults to undef
#
# [*disable_email*]
#   (optional) Disable e-mail notifications
#   Defaults to true
# 
# [*enable_cron*]
#   (optional) Enable cron jobs to run Delorean on the worker every 5 minutes
#   Defaults to false
#
# [*symlinks*]
#   (optional) List of directories to be symlinked under to the repo directory
#   Example: ['/var/www/html/f22','/var/www/html/f21']
#   Defaults to undef
#
# [*release*]
#   (optional) Release this worker will be using (all lowercase)
#   Example: 'mitaka'
#   Defaults to 'mitaka'
#
# [*gerrit_user*]
#   (optional) User to run Gerrit reviews after build failures. If set to undef,
#     do not enable Gerrit reviews
#   Example: 'rdo-trunk'
#   Defaults to undef
# 
# === Example
#
#  delorean::worker {'centos-master':
#    distro         => 'centos7',
#    target         => 'centos',
#    distgit_branch => 'rpm-master',
#    distro_branch  => 'master',
#    uid            => 1000,
#    disable_email  => true,
#    enable_cron    => false,
#    release        => 'mitaka',
#  }

define delorean::worker (
  $distro,
  $target,
  $distgit_branch = 'rpm-master',
  $distro_branch  = 'master',
  $uid            = undef,
  $disable_email  = true,
  $enable_cron    = false,
  $symlinks       = undef,
  $release        = 'mitaka',
  $gerrit_user    = undef ) {

  user { $name:
    comment    => $name,
    groups     => ['users', 'mock'],
    home       => "/home/${name}",
    managehome => true,
    uid        => $uid,
  }

  file {"/home/${name}":
    ensure => directory,
    owner  => $name,
    mode   => '0755',
  } ->
  exec { "ensure home contents belong to ${name}":
    command => "chown -R ${name}:${name} /home/${name}",
    path    => '/usr/bin',
    timeout => 900,
  } ->
  file { "/home/${name}/data":
    ensure => directory,
    mode   => '0755',
    owner  => $name,
    group  => $name,
  } ->
  file { "/home/${name}/data/repos":
    ensure => directory,
    mode   => '0755',
    owner  => $name,
    group  => $name,
  } ->
  file { "/home/${name}/data/repos/delorean-deps.repo":
    ensure => present,
    source => "puppet:///modules/delorean/${name}-delorean-deps.repo",
    mode   => '0644',
    owner  => $name,
    group  => $name,
  }

  exec { "${name}-sshkeygen":
    command => "ssh-keygen -t rsa -P \"\" -f /home/${name}/.ssh/id_rsa",
    path    => '/usr/bin',
    creates => "/home/${name}/.ssh/id_rsa",
    user    => $name,
  }

  exec { "venv-${name}":
    command => "virtualenv /home/${name}/.venv",
    path    => '/usr/bin',
    creates => "/home/${name}/.venv",
    cwd     => "/home/${name}",
    user    => $name,
  }

  vcsrepo { "/home/${name}/delorean":
    ensure   => present,
    provider => git,
    source   => 'https://github.com/openstack-packages/delorean',
    user     => $name,
    require  => File["/home/${name}"]
  }

  file { "/home/${name}/setup_delorean.sh":
    ensure  => present,
    mode    => '0755',
    content => "source /home/${name}/.venv/bin/activate
pip install -r requirements.txt
pip install -r test-requirements.txt
python setup.py develop",
  }

  if $disable_email {
    $delorean_mailserver = ''
  } else {
    $delorean_mailserver = 'localhost'
  }

  exec { "pip-install-${name}":
    command => "/home/${name}/setup_delorean.sh",
    cwd     => "/home/${name}/delorean",
    path    => '/usr/bin',
    creates => "/home/${name}/.venv/bin/delorean",
    require => [Exec["venv-${name}"], Vcsrepo["/home/${name}/delorean"], File["/home/${name}/setup_delorean.sh"]],
    user    => $name,
  }

  # Special case for non-master
  if $name =~ /^(centos|fedora)\-(kilo|liberty|mitaka)/ {
    $baseurl_components = split($distro_branch, '/')
    $baseurl_target     = "${distro}-${baseurl_components[1]}"
  } else {
    $baseurl_target = $distro
  }

  file { "/usr/local/share/delorean/${name}":
    ensure => directory,
    mode   => '0755',
  } ->
  file { "/usr/local/share/delorean/${name}/projects.ini":
    ensure  => present,
    content => template('delorean/projects.ini.erb'),
  }

  sudo::conf { $name:
      priority => 10,
      content  => "${name} ALL=(ALL) NOPASSWD: /bin/rm",
  }

  file { "/etc/logrotate.d/delorean-${name}":
    ensure  => present,
    content => template('delorean/logrotate.erb'),
    mode    => '0644',
  }

  if $enable_cron {
    cron { $name:
      command => '/usr/local/bin/run-delorean.sh',
      user    => $name,
      hour    => '*',
      minute  => '*/5'
    }
  }

  # Set up symlinks
  if $symlinks {
    file { $symlinks :
      ensure  => link,
      target  => "/home/${name}/data/repos",
      require => Package['httpd'],
    }
  }

  # Set up synchronization
  if $::delorean::backup_server  {
    delorean::lsyncdconfig { "lsync-${name}":
      path         => "/home/${name}",
      sshd_port    => $::delorean::sshd_port,
      remoteserver => $::delorean::backup_server,
    }
  }

  # Special case for fedora-rawhide-master
  if $name == 'fedora-rawhide-master' {
    file { "/home/${name}/delorean/scripts/fedora-rawhide.cfg":
      ensure  => present,
      source  => 'puppet:///modules/delorean/fedora-rawhide.cfg',
      mode    => '0644',
      owner   => $name,
      require => Vcsrepo["/home/${name}/delorean"],
    }
  }

  # Special case for *-mitaka, *-liberty and *-kilo
  if $name =~ /^(centos|fedora)\-(kilo|liberty|mitaka)/ {
    $components     = split($name, '-')
    $worker_os      = $components[0]
    $worker_version = $components[1]

    file { "/home/${name}/delorean/scripts/${worker_os}-${worker_version}.cfg":
      ensure  => present,
      content => template("delorean/${worker_os}.cfg.erb"),
      require => Vcsrepo["/home/${name}/delorean"],
    }

    file { "/var/www/html/${worker_os}-${worker_version}":
      ensure  => directory,
      mode    => '0755',
      path    => "/var/www/html/${worker_version}",
      require => Package['httpd'],
    }
  }

  # Set up gerrit, if configured
  if $gerrit_user {
    exec { "Set gerrit user for ${name}":
      command     => "git config --global --add gitreview.username ${gerrit_user}",
      path        => '/usr/bin',
      user        => $name,
      cwd         => "/home/${name}",
      environment => "HOME=/home/${name}",
      require     => File["/home/${name}"],
    }

    exec { "Set git user for ${name}":
      command     => "git config --global user.name ${gerrit_user}",
      path        => '/usr/bin',
      user        => $name,
      cwd         => "/home/${name}",
      environment => "HOME=/home/${name}",
      require     => File["/home/${name}"],
    }

    exec { "Set git email for ${name}":
      command     => "git config --global user.email ${gerrit_user}@rdoproject.org",
      path        => '/usr/bin',
      user        => $name,
      cwd         => "/home/${name}",
      environment => "HOME=/home/${name}",
      require     => File["/home/${name}"],
    }
  }
}
