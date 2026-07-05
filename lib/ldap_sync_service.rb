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
    @report_email = LdapSetting.get('report_email')
    @send_report_only_on_changes = LdapSetting.get('send_report_only_on_changes') == 'true'
    
    @stats = { 
      users_in_redmine: 0,
      users_locked: 0, 
      users_unlocked: 0, 
      groups_processed: 0, 
      users_added: 0, 
      users_removed: 0
    }
    
    @created_groups = []
    @unchanged_groups = []
    @changes = []
    @user_locks = []
    @user_unlocks = []
    @all_groups = []
  end
  
  def log(msg, level = 'info')
    puts "[#{Time.now}] #{msg}"

    if @dry_run || @verbose
      SyncLog.create(message: msg, level: level)
    else
      important_patterns = ['===', '---', 'Group filter', '✅ Groups processed',
                            '✅ Users synced', '📊', '✓ No changes', 'ADD user',
                            'REMOVE user', 'LOCK user', 'UNLOCK user', 'Create group']

      if important_patterns.any? { |pattern| msg.include?(pattern) }
        SyncLog.create(message: msg, level: level)
      end
    end
  end

  def log_error(msg)
    puts "[#{Time.now}] ERROR: #{msg}"
    SyncLog.create(message: "ERROR: #{msg}", level: 'error')
    @changes << "ERROR: #{msg}"
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
      send_report if @report_email.present?
      return @stats
    end
    
    log("--- Syncing users ---")
    sync_users(ldap)
    
    log("--- Syncing groups ---")
    if @group_prefix.empty?
      log("Group filter: ALL groups from #{@groups_dn}")
    else
      log("Group filter: Only groups with prefix '#{@group_prefix}'")
    end
    sync_groups(ldap)
    
    # Afișare grupuri procesate
    if @all_groups.any?
      log("✅ Groups processed: #{@all_groups.size} groups (#{@all_groups.join(', ')})")
    else
      log("✅ Groups processed: #{@stats[:groups_processed]}")
    end
    
    log("📊 Users in Redmine: #{@stats[:users_in_redmine]}, Locked: #{@stats[:users_locked]}, Unlocked: #{@stats[:users_unlocked]}")
    log("📊 Groups: #{@stats[:groups_processed]} processed, #{@stats[:users_added]} added, #{@stats[:users_removed]} removed")
    log("=== Sync Complete ===")
    
    # Trimite raport
    send_report if @report_email.present?
    
    @stats
  end
  
  def sync_users(ldap)
    filter = Net::LDAP::Filter.eq("objectClass", "user")
    redmine_users_count = 0
    
    ldap.search(base: @users_dn, filter: filter, attributes: ['sAMAccountName', 'userAccountControl']) do |entry|
      username = entry[:samaccountname]&.first
      next unless username
      
      user = User.find_by(login: username.downcase)
      if user
        redmine_users_count += 1
        @stats[:users_in_redmine] += 1
      else
        next
      end
      
      uac = entry[:useraccountcontrol]&.first.to_i
      disabled = (uac & 2) == 2
      
      if disabled && user.active?
        log("🔒 LOCK user: #{username}")
        @user_locks << username
        @changes << "🔒 Locked user: #{username}"
        unless @dry_run
          user.lock!
          user.save!
        end
        @stats[:users_locked] += 1
      elsif !disabled && user.locked?
        log("🔓 UNLOCK user: #{username}")
        @user_unlocks << username
        @changes << "🔓 Unlocked user: #{username}"
        unless @dry_run
          user.activate!
          user.save!
        end
        @stats[:users_unlocked] += 1
      end
    end
    
    log("✅ Users synced: #{redmine_users_count} in Redmine, #{@user_locks.size} locked, #{@user_unlocks.size} unlocked")
  end
  
  def sync_groups(ldap)
    filter = Net::LDAP::Filter.eq("objectClass", "group")
    
    ldap.search(base: @groups_dn, filter: filter, attributes: ['cn', 'member']) do |entry|
      cn = entry[:cn]&.first
      next unless cn
      
      if @group_prefix.present? && !cn.start_with?(@group_prefix)
        next
      end
      
      group_name = @group_prefix.present? ? cn.delete_prefix(@group_prefix) : cn
      @stats[:groups_processed] += 1
      @all_groups << group_name
      
      # Find or create Redmine group
      group = Group.find_by(lastname: group_name)
      group_created = false
      
      if group.nil? && !@dry_run
        group = Group.create(lastname: group_name)
        group_created = true
        @created_groups << group_name
        @changes << "📁 Created group: #{group_name}"
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
          @stats[:users_added] += 1
          added_users << username
          @changes << "➕ Added user #{username} to group #{group_name}"
        end
      end
      
      # Remove users not in LDAP group
      group.users.each do |user|
        unless ldap_members.include?(user.login.downcase)
          group.users.delete(user) unless @dry_run
          @stats[:users_removed] += 1
          removed_users << user.login
          @changes << "➖ Removed user #{user.login} from group #{group_name}"
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
  
  def send_report
    return if @report_email.blank?
    
    # Dacă e configurat să trimită doar la modificări și nu există modificări, nu trimite
    if @send_report_only_on_changes && @changes.empty?
      puts "No changes detected. Report not sent."
      return
    end
    
    subject = "Redmine LDAP Sync Groups - #{Time.now.strftime('%Y-%m-%d %H:%M')}"
    
    if @changes.empty?
      body = "No changes detected during LDAP synchronization.\n\n"
      body += "=== Statistics ===\n"
      body += "Users in Redmine: #{@stats[:users_in_redmine]}\n"
      body += "Groups processed: #{@stats[:groups_processed]} groups\n"
      if @all_groups.any?
        body += "Groups list: #{@all_groups.join(', ')}\n"
      end
      body += "Dry run: #{@dry_run ? 'Yes (no changes applied)' : 'No'}\n"
    else
      body = "=== LDAP Sync Changes Report ===\n\n"
      body += "Synchronization completed at: #{Time.now}\n"
      body += "Dry run: #{@dry_run ? 'Yes (no changes applied)' : 'No'}\n\n"
      
      body += "=== Statistics ===\n"
      body += "Users in Redmine: #{@stats[:users_in_redmine]}\n"
      body += "Users locked: #{@stats[:users_locked]}\n"
      body += "Users unlocked: #{@stats[:users_unlocked]}\n"
      body += "Groups processed: #{@stats[:groups_processed]} groups\n"
      if @all_groups.any?
        body += "Groups list: #{@all_groups.join(', ')}\n"
      end
      body += "Users added to groups: #{@stats[:users_added]}\n"
      body += "Users removed from groups: #{@stats[:users_removed]}\n\n"
      
      body += "=== Changes ===\n"
      @changes.each do |change|
        body += "• #{change}\n"
      end
    end
    
    body += "\n---\n"
    body += "LDAP Sync Plugin v2.2 | Steel..xD"
    
    begin
      ActionMailer::Base.mail(
        from: Setting.mail_from,
        to: @report_email,
        subject: subject,
        body: body
      ).deliver
      puts "✅ Report sent to #{@report_email}"
    rescue => e
      puts "❌ Failed to send report: #{e.message}"
    end
  end
end
