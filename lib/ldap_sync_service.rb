require 'net/ldap'

class LdapSyncService
  def initialize(dry_run = false)
    @dry_run = dry_run
    
    auth_id = LdapSetting.get('ldap_auth_id').to_i
    @auth = AuthSourceLdap.find_by(id: auth_id)
    
    if @auth.nil?
      raise "No LDAP authentication mode selected. Please configure in plugin settings."
    end
    
    @host = @auth.host
    @port = @auth.port
    @bind_dn = @auth.account
    @password = @auth.account_password
    @users_dn = @auth.base_dn
    @groups_dn = LdapSetting.get('ldap_groups_dn')
    @group_prefix = LdapSetting.get('ldap_group_prefix') || ''
    @verbose = LdapSetting.get('verbose_logging') == 'true'
    
    @stats = { 
      users: 0, 
      locked: 0, 
      unlocked: 0, 
      groups: 0, 
      added: 0, 
      removed: 0
    }
    
    @created_groups = []
    @unchanged_groups = []
    @user_changes = []
  end
  
  def log(msg, level = 'info')
    puts "[#{Time.now}] #{msg}"
    
    unless @dry_run
      if @verbose
        SyncLog.create(message: msg, level: level)
      else
        # Salvăm doar mesajele importante
        important_patterns = ['===', '---', 'Group filter', '✅ Groups processed', 
                              '✅ Users synced', '📊', '✓ No changes', 'ADD user', 
                              'REMOVE user', 'LOCK user', 'UNLOCK user', 'Create group']
        
        if important_patterns.any? { |pattern| msg.include?(pattern) }
          SyncLog.create(message: msg, level: level)
        end
      end
    end
  end
  
  def log_error(msg)
    puts "[#{Time.now}] ERROR: #{msg}"
    SyncLog.create(message: "ERROR: #{msg}", level: 'error') unless @dry_run
  end
  
  def run
    log("=== LDAP Sync Started (DRY RUN: #{@dry_run}) ===")
    
    ldap = Net::LDAP.new(
      host: @host,
      port: @port,
      encryption: @port == 636 ? :simple_tls : nil,
      auth: { method: :simple, username: @bind_dn, password: @password }
    )
    
    unless ldap.bind
      log_error("Cannot bind to LDAP server #{@host}:#{@port}")
      return @stats
    end
    
    # Nu mai logăm "Connected to LDAP server" și "LDAP Server"
    
    log("--- Syncing users ---")
    sync_users(ldap)
    
    log("--- Syncing groups ---")
    if @group_prefix.empty?
      log("Group filter: ALL groups from #{@groups_dn}")
    else
      log("Group filter: Only groups with prefix '#{@group_prefix}'")
    end
    sync_groups(ldap)
    
    log("✅ Groups processed: #{@stats[:groups]}")
    log("📊 Users: #{@stats[:users]} processed, #{@stats[:locked]} locked, #{@stats[:unlocked]} unlocked")
    log("📊 Groups: #{@stats[:groups]} processed, #{@stats[:added]} added, #{@stats[:removed]} removed")
    log("=== Sync Complete ===")
    
    @stats
  end
  
  def sync_users(ldap)
    filter = Net::LDAP::Filter.eq("objectClass", "user")
    processed = 0
    locked_users = []
    unlocked_users = []
    
    ldap.search(base: @users_dn, filter: filter, attributes: ['sAMAccountName', 'userAccountControl']) do |entry|
      username = entry[:samaccountname]&.first
      next unless username
      
      @stats[:users] += 1
      processed += 1
      
      user = User.find_by(login: username.downcase)
      next unless user
      
      uac = entry[:useraccountcontrol]&.first.to_i
      disabled = (uac & 2) == 2
      
      if disabled && user.active?
        log("🔒 LOCK user: #{username}")
        unless @dry_run
          user.lock!
          # Force save
          user.save!
        end
        @stats[:locked] += 1
        locked_users << username
      elsif !disabled && user.locked?
        log("🔓 UNLOCK user: #{username}")
        unless @dry_run
          user.activate!
          # Force save
          user.save!
        end
        @stats[:unlocked] += 1
        unlocked_users << username
      end
    end
    
    log("✅ Users synced: #{processed} total, #{locked_users.size} locked, #{unlocked_users.size} unlocked")
  end
  
  def sync_groups(ldap)
    filter = Net::LDAP::Filter.eq("objectClass", "group")
    group_changes = []
    
    ldap.search(base: @groups_dn, filter: filter, attributes: ['cn', 'member']) do |entry|
      cn = entry[:cn]&.first
      next unless cn
      
      if @group_prefix.present? && !cn.start_with?(@group_prefix)
        next
      end
      
      group_name = cn
      @stats[:groups] += 1
      
      # Find or create Redmine group
      group = Group.find_by(lastname: group_name)
      group_created = false
      
      if group.nil? && !@dry_run
        group = Group.create(lastname: group_name)
        group_created = true
        @created_groups << group_name
      end
      
      if group.nil?
        next
      end
      
      # Get members from LDAP
      ldap_members = []
      added_users = []
      removed_users = []
      
      entry[:member]&.each do |member_dn|
        cn_match = member_dn.to_s.match(/CN=([^,]+)/i)
        next unless cn_match
        
        cn_username = cn_match[1]
        
        # Get sAMAccountName
        user_filter = Net::LDAP::Filter.eq("distinguishedName", member_dn)
        sam_account = nil
        
        ldap.search(base: @users_dn, filter: user_filter, attributes: ['sAMAccountName']) do |user_entry|
          sam_account = user_entry[:samaccountname]&.first
        end
        
        username = sam_account || cn_username
        ldap_members << username.downcase
        user = User.find_by(login: username.downcase)
        
        if user && !group.users.include?(user)
          group.users << user unless @dry_run
          @stats[:added] += 1
          added_users << username
          group_changes << "ADD user: #{username} to #{group_name}"
        end
      end
      
      # Remove users not in LDAP group
      group.users.each do |user|
        unless ldap_members.include?(user.login.downcase)
          group.users.delete(user) unless @dry_run
          @stats[:removed] += 1
          removed_users << user.login
          group_changes << "REMOVE user: #{user.login} from #{group_name}"
        end
      end
      
      # Log changes
      added_users.each { |u| log("➕ ADD user: #{u} to #{group_name}") }
      removed_users.each { |u| log("➖ REMOVE user: #{u} from #{group_name}") }
      
      if group_created
        log("📁 Create group: #{group_name}")
      elsif added_users.empty? && removed_users.empty?
        @unchanged_groups << group_name
      end
    end
    
    # Log unchanged groups
    if @unchanged_groups.any?
      log("✓ No changes for group: #{@unchanged_groups.join(', ')}")
    end
    
    # Log created groups
    if @created_groups.any?
      log("📁 Create groups: #{@created_groups.join(', ')}")
    end
  end
end
