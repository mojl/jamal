# frozen_string_literal: true

require_relative "jamal/version"
require 'net/ssh'
require 'net/sftp'
require 'yaml'
require 'fileutils'
require 'tempfile'

module Jamal
  class Error < StandardError; end

  class CLI
    def self.setup(config_path: '_jamal.yml')
      # Load configuration
      config = YAML.load_file(config_path)
      
      begin
        # Establish SSH connection using config values
        Net::SSH.start(config['host'], config['user'],
          password: config['password']
        ) do |ssh|
          puts "Connected to #{config['host']}..."
          
          # Check if nginx is installed
          result = ssh.exec!("nginx -v")
          if result && !result.include?("not found")
            puts "nginx is already installed"
          else
            puts "Installing nginx..."
            # Update package list and install nginx
            ssh.exec!("sudo apt-get update")
            ssh.exec!("sudo apt-get install -y nginx")
            
            # Verify installation
            result = ssh.exec!("nginx -v")
            if result && !result.include?("not found")
              puts "nginx installed successfully"
            else
              raise Error, "Failed to install nginx"
            end
          end

          # Set up rsync daemon configuration
          puts "Setting up rsync daemon..."
          
          # Create rsyncd configuration with consistent user permissions
          rsyncd_conf = <<~CONFIG
            uid = #{config['user']}
            gid = #{config['user']}
            use chroot = no
            max connections = 4
            pid file = /var/run/rsyncd.pid
            exclude = .git/ .gitignore

            [#{config['name']}]
                path = /var/www/#{config['name']}
                comment = Website files for #{config['name']}
                read only = no
                auth users = #{config['name']}
                secrets file = /etc/rsyncd.secrets
          CONFIG

          # Generate a random password for rsync
          special_chars = '!@#$%^&*()_+-=[]{}|;:,.<>?'.chars
          numbers = '0123456789'.chars
          letters = ('a'..'z').to_a + ('A'..'Z').to_a
          rsync_password = (letters + numbers + special_chars).shuffle[0,16].join
          
          # First, clean up any existing entries for both the site name and root user
          ssh.exec!("sudo sed -i '/^#{config['name']}:/d' /etc/rsyncd.secrets")

          # Add new entry with the website name
          ssh.exec!("echo '#{config['name']}:#{rsync_password}' | sudo tee -a /etc/rsyncd.secrets")
          ssh.exec!("sudo chmod 600 /etc/rsyncd.secrets")
          
          # Remove any existing module configuration and create new one
          ssh.exec!("sudo sed -i '/\\[#{config['name']}\\]/,/^$/d' /etc/rsyncd.conf")
          
          # Write the full rsyncd configuration
          ssh.exec!("echo '#{rsyncd_conf}' | sudo tee -a /etc/rsyncd.conf")
          
          # Update the config file with the rsync password
          config['rsync_password'] = rsync_password
          File.write(config_path, config.to_yaml)
          
          # Enable and start rsync daemon
          ssh.exec!("sudo systemctl enable rsync")
          ssh.exec!("sudo systemctl start rsync")
          
          puts "Rsync daemon configured successfully!"
        end
      rescue Net::SSH::AuthenticationFailed
        raise Error, "SSH authentication failed"
      rescue StandardError => e
        raise Error, "Setup failed: #{e.message}"
      end
    end

    def self.deploy(config_path: '_jamal.yml')
      # Load configuration
      config = YAML.load_file(config_path)
      temp_password_file = nil  # Declare variable outside begin block
      
      begin
        Net::SSH.start(config['host'], config['user'],
          password: config['password']
        ) do |ssh|
          puts "Connected to #{config['host']}..."
          
          # Check rsync daemon status
          puts "Checking rsync daemon status..."
          status = ssh.exec!("sudo systemctl status rsync")
          unless status.include?("active (running)")
            puts "Restarting rsync daemon..."
            ssh.exec!("sudo systemctl restart rsync")
          end
          
          # Create nginx configuration with support for multiple domains
          nginx_config = <<~CONFIG
            server {
              listen 80;
              server_name #{Array(config['domains']).join(' ')};
              root /var/www/#{config['name']};
              index index.html index.htm;
              
              location / {
                try_files $uri $uri/ =404;
              }
            }
          CONFIG
          
          # Check if nginx config already exists and is the same
          existing_config = ssh.exec!("sudo cat /etc/nginx/sites-available/#{config['name']} 2>/dev/null")
          if existing_config == nginx_config
            puts "Nginx configuration unchanged, skipping update..."
          else
            # Create directory and upload nginx config
            puts "Setting up nginx configuration..."
            ssh.exec!("sudo mkdir -p /var/www/#{config['name']}")
            ssh.exec!("sudo chown -R #{config['user']}:#{config['user']} /var/www/#{config['name']}")
            ssh.exec!("sudo chmod -R 755 /var/www/#{config['name']}")
            
            # Upload nginx config using SFTP
            File.write('/tmp/temp_nginx.conf', nginx_config)
            ssh.sftp.connect do |sftp|
              sftp.upload!('/tmp/temp_nginx.conf', "/tmp/#{config['name']}.conf")
              File.delete('/tmp/temp_nginx.conf')
            end
            
            # Move config to nginx sites and enable it
            ssh.exec!("sudo mv /tmp/#{config['name']}.conf /etc/nginx/sites-available/#{config['name']}")
            ssh.exec!("sudo ln -sf /etc/nginx/sites-available/#{config['name']} /etc/nginx/sites-enabled/")
            
            # Test and reload nginx
            puts "Testing nginx configuration..."
            result = ssh.exec!("sudo nginx -t")
            if result && !result.include?("error")
              ssh.exec!("sudo systemctl reload nginx")
              puts "Nginx configuration updated successfully!"
            else
              raise Error, "Invalid nginx configuration"
            end
          end

          # Replace SSH-based rsync with daemon-based rsync
          local_path = config['local_path']
          local_path = "#{local_path}/" unless local_path.end_with?('/')
          
          # Create temporary password file for rsync
          temp_password_file = Tempfile.new('rsync_password')
          temp_password_file.write(config['rsync_password'])
          temp_password_file.close
          FileUtils.chmod(0600, temp_password_file.path)

          # Build rsync command for daemon mode with simplified output
          rsync_cmd = [
            "rsync",
            "-ahi",                   # archive mode, human-readable, itemize changes
            "--delete",              # delete extraneous files
            "--out-format='%i | %n'", # simplified output format showing changes and filename
            "--password-file=#{temp_password_file.path}",
            local_path,
            "rsync://#{config['name']}@#{config['host']}/#{config['name']}/"
          ].join(" ")
          
          # Execute rsync with better error handling
          puts "Syncing website files..."

          IO.popen(rsync_cmd) do |io|
            while line = io.gets
              info = line.partition('|').first.strip
              filename = line.partition('|').last.strip

              if info[0] == '<'
                puts "Uploading    #{filename}"
              elsif info[0] == '.'
                if info[1] == 'd'
                  puts "Acessing     #{filename}"
                else
                  puts "Unchanged    #{filename}"
                end
              elsif info == "*deleting"
                puts "Deleting    #{filename}"
              elsif info == "cd+++++++++"
                puts "Creating     #{filename}"
              else
                puts line
              end
            end
          end

          exit_status = $?.exitstatus
          
          # Clean up temporary password file
          temp_password_file.unlink
          
          if exit_status != 0
            puts "Rsync failed. Checking daemon accessibility..."
            system("nc -zv #{config['host']} 873")
            raise Error, "Rsync failed with status: #{exit_status}. Please check the rsync daemon is running and port 873 is accessible."
          end
          
          puts "Sync completed!"
        end
      rescue Net::SSH::AuthenticationFailed
        raise Error, "SSH authentication failed"
      rescue StandardError => e
        raise Error, "Deployment failed: #{e.message}"
      ensure
        # Now temp_password_file will be in scope
        temp_password_file&.unlink
      end
    end

    def self.remove(config_path: '_jamal.yml')
      # Load configuration
      config = YAML.load_file(config_path)
      
      begin
        Net::SSH.start(config['host'], config['user'],
          password: config['password']
        ) do |ssh|
          puts "Connected to #{config['host']}..."
          
          # Remove nginx configuration
          puts "Removing nginx configuration..."
          ssh.exec!("sudo rm -f /etc/nginx/sites-enabled/#{config['name']}")
          ssh.exec!("sudo rm -f /etc/nginx/sites-available/#{config['name']}")
          ssh.exec!("sudo systemctl reload nginx")
          
          # Remove website files
          puts "Removing website files..."
          ssh.exec!("sudo rm -rf /var/www/#{config['name']}")
          
          # Remove rsync secrets
          puts "Removing rsync secrets..."
          ssh.exec!("sudo sed -i '/#{config['name']}:.*$/d' /etc/rsyncd.secrets")
          
          # Remove rsync configuration
          puts "Removing rsync configuration..."
          ssh.exec!("sudo sed -i '/\\[#{config['name']}\\]/,/^$/d' /etc/rsyncd.conf")
          
          # Clean up empty lines in rsync config
          ssh.exec!("sudo sed -i '/^$/N;/^\\n$/D' /etc/rsyncd.conf")
          
          # Remove rsync_password from local config file
          config.delete('rsync_password')
          File.write(config_path, config.to_yaml)
          
          puts "Successfully removed all configurations for #{config['name']}!"
        end
      rescue Net::SSH::AuthenticationFailed
        raise Error, "SSH authentication failed"
      rescue StandardError => e
        raise Error, "Removal failed: #{e.message}"
      end
    end

    def self.init(config_path: '_jamal.yml')
      # Create the config file
      File.write(config_path, {
        'name' => 'example',
        'host' => '1.2.3.4',
        'user' => 'root',
        'password' => 'password',
        'domains' => ['example.com', 'www.example.com'],
        'local_path' => './_site'
      }.to_yaml)
      puts "Created #{config_path} with default configuration."
    end
  end
end

