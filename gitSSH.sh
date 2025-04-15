#!/bin/bash

# --- Helper Functions ---
print_step() {
  echo -e "\n\e[1;36m=== $1 ===\e[0m"
}

print_info() {
  echo -e "\e[34mINFO: $1\e[0m"
}

print_success() {
  echo -e "\e[32mSUCCESS: $1\e[0m"
}

print_warning() {
  echo -e "\e[33mWARNING: $1\e[0m"
}

print_error() {
  echo -e "\e[31mERROR: $1\e[0m" >&2
}

ask_question() {
  local prompt="$1"
  local default_value="$2"
  local user_input
  if [[ -n "$default_value" ]]; then
    read -p "$prompt [$default_value]: " user_input
    echo "${user_input:-$default_value}"
  else
    read -p "$prompt: " user_input
    echo "$user_input"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="$2" # 'y' or 'n'
  local answer

  while true; do
    if [[ "$default" == "y" ]]; then
        read -p "$prompt [Y/n]: " answer
        answer=${answer:-y}
    elif [[ "$default" == "n" ]]; then
        read -p "$prompt [y/N]: " answer
        answer=${answer:-n}
    else
        read -p "$prompt [y/n]: " answer
    fi

    case $answer in
        [Yy]* ) return 0;; # 0 for yes
        [Nn]* ) return 1;; # 1 for no
        * ) echo "Please answer yes (y) or no (n).";;
    esac
  done
}

# --- Script Start ---
echo -e "\e[1;35m*** Interactive Guide: Setup SSH for GitHub & Initial Push ***\e[0m"
echo "This script will help you set up an SSH key, connect to GitHub, and perform the initial push."

# --- Step 1: Check Prerequisites ---
print_step "1. Checking Prerequisites"
command -v git >/dev/null 2>&1 || { print_error "Git is not installed. Please install Git first."; exit 1; }
command -v ssh >/dev/null 2>&1 || { print_error "OpenSSH Client is not installed. Please install it (e.g., openssh-client package)."; exit 1; }
command -v ssh-keygen >/dev/null 2>&1 || { print_error "ssh-keygen command not found."; exit 1; }
command -v ssh-agent >/dev/null 2>&1 || { print_error "ssh-agent command not found."; exit 1; }
command -v ssh-add >/dev/null 2>&1 || { print_error "ssh-add command not found."; exit 1; }
print_success "Required tools (git, ssh, ssh-keygen, ssh-agent, ssh-add) found."

# --- Step 2: Set Local Repository Path ---
print_step "2. Set Local Repository Path"
repo_path=$(ask_question "Please enter the full path to your local Git repository" "$(pwd)")
if [[ ! -d "$repo_path" ]]; then
  print_error "The entered path is not a valid directory."
  exit 1
fi
cd "$repo_path" || { print_error "Failed to change directory to $repo_path."; exit 1; }
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
   print_error "The path '$repo_path' is not a valid Git repository. Run 'git init' first."
   exit 1
fi
print_success "You are now inside the repository path: $(pwd)"

# --- Step 3: User Info & SSH Key ---
print_step "3. Configure SSH Key"
github_email=$(ask_question "Enter the email associated with your GitHub account")
default_ssh_key_path="$HOME/.ssh/id_ed25519"
ssh_key_path="$default_ssh_key_path" # Default for now

generate_new_key=false
if [ -f "${ssh_key_path}.pub" ]; then
  print_info "An SSH key was found at the default path: ${ssh_key_path}"
  if ask_yes_no "Do you want to use this existing key?" "y"; then
    print_info "Using the existing key."
  else
    ssh_key_path=$(ask_question "Enter a new path for the key, or the same path to overwrite" "$default_ssh_key_path")
    if [ -f "$ssh_key_path" ] || [ -f "${ssh_key_path}.pub" ]; then
        if ! ask_yes_no "Key file exists at '$ssh_key_path'. Are you sure you want to overwrite it?" "n"; then
            print_error "Operation cancelled."
            exit 1
        fi
         # Remove old keys before generating new ones at the same path
         rm -f "$ssh_key_path" "${ssh_key_path}.pub"
    fi
    generate_new_key=true
  fi
else
  print_info "SSH key not found at the default path."
  if ask_yes_no "Do you want to create a new SSH key at the default path ($ssh_key_path)?" "y"; then
    generate_new_key=true
  else
    print_error "Cannot proceed without an SSH key. Operation cancelled."
    exit 1
  fi
fi

if $generate_new_key; then
  print_info "Generating a new ed25519 SSH key..."
  echo "When prompted, you can press Enter to use the default file path '$ssh_key_path'."
  echo "You will also be asked to create a 'passphrase' for your key."
  echo "   - Entering a passphrase significantly increases key security (Recommended)."
  echo "   - Leaving the passphrase empty (press Enter twice) is easier but less secure."
  ssh-keygen -t ed25519 -C "$github_email" -f "$ssh_key_path"
  if [ $? -ne 0 ]; then
    print_error "Failed to generate SSH key."
    exit 1
  fi
  print_success "New SSH key successfully generated at '$ssh_key_path'."
  # Set correct permissions
  mkdir -p ~/.ssh # Ensure directory exists
  chmod 700 ~/.ssh
  chmod 600 "$ssh_key_path"
  chmod 644 "${ssh_key_path}.pub"
fi

# --- Step 4: Add Public Key to GitHub ---
print_step "4. Add Public Key to GitHub"
print_info "Your public key content (${ssh_key_path}.pub) to add to GitHub:"
echo "---------------------------------------------"
echo -e "\e[36m" # Start cyan color
cat "${ssh_key_path}.pub"
echo -e "\e[0m" # Reset color
echo "---------------------------------------------"
echo ""
print_warning "--> ACTION REQUIRED <--"
print_warning "1. Copy the entire public key text above (starting with 'ssh-ed25519...' and ending with your email)."
print_warning "2. Go to your GitHub account settings in your browser (Settings -> SSH and GPG keys)."
print_warning "3. Click on 'New SSH key' or 'Add SSH key'."
print_warning "4. Give it a descriptive Title (e.g., 'My Debian Server Script') and paste the copied key into the 'Key' field."
print_warning "5. Click 'Add SSH key'."
echo ""
read -p ">>> Press [Enter] after you have added the key to GitHub..."

# --- Step 5: Start and Use ssh-agent ---
print_step "5. Start ssh-agent and Add Key"
ssh-add -l > /dev/null 2>&1
if [ $? -ne 0 ]; then
  print_info "ssh-agent is not running or unavailable. Starting agent..."
  eval "$(ssh-agent -s)"
  if [ $? -ne 0 ]; then
    print_error "Failed to start ssh-agent."
    exit 1
  fi
  print_success "ssh-agent started."
else
  print_success "ssh-agent is already running."
fi

print_info "Adding SSH key to agent..."
echo "If you set a passphrase for your key, you will be prompted for it now."
ssh-add "$ssh_key_path"
if [ $? -ne 0 ]; then
  print_error "Failed to add SSH key to agent. Did you enter the correct passphrase?"
  exit 1
fi
print_success "SSH key successfully added to agent."

# --- Step 6: Test SSH Connection to GitHub ---
print_step "6. Test SSH Connection to GitHub"
print_info "Testing connection..."
# Showing the output is helpful for the user
ssh -T git@github.com
ssh_exit_code=$?
# Exit code 1 is expected for success here
if [ $ssh_exit_code -eq 1 ]; then
  print_success "SSH connection to GitHub successful!"
else
  # Other codes (like 255) indicate failure
  print_error "SSH connection to GitHub failed (Exit code: $ssh_exit_code)."
  print_error "Please double-check that you added the public key correctly to GitHub and waited a moment."
  print_error "Also ensure you entered the correct passphrase (if any) when prompted by ssh-add or ssh."
  exit 1
fi

# --- Step 7: Configure Git Remote ---
print_step "7. Configure Git Remote"
remote_name=$(ask_question "Enter the remote name (usually 'origin')" "origin")
print_info "Please enter the SSH URL of your GitHub repository."
print_info "This URL should look like 'git@github.com:USERNAME/REPONAME.git'."
ssh_url=$(ask_question "SSH URL:")

# Basic check for SSH URL format
if [[ ! "$ssh_url" == git@github.com:* ]] || [[ ! "$ssh_url" == *.git ]]; then
    print_warning "The entered URL ('$ssh_url') does not look like a typical GitHub SSH URL (e.g., git@github.com:user/repo.git). Please double-check."
    if ! ask_yes_no "Do you want to continue with this URL anyway?" "y"; then
        print_error "Operation cancelled."
        exit 1
    fi
fi

existing_url=$(git remote get-url "$remote_name" 2>/dev/null)
if [[ -n "$existing_url" ]]; then
  print_info "Remote '$remote_name' already exists with URL '$existing_url'."
  if [[ "$existing_url" != "$ssh_url" ]]; then
    if ask_yes_no "Do you want to change the URL of remote '$remote_name' to the new SSH URL ('$ssh_url')?" "y"; then
      git remote set-url "$remote_name" "$ssh_url"
      print_success "Remote '$remote_name' URL updated."
    else
      print_info "Remote URL not changed."
    fi
  else
     print_info "Remote '$remote_name' URL is already correct."
  fi
else
  print_info "Remote '$remote_name' does not exist. Adding it..."
  git remote add "$remote_name" "$ssh_url"
  if [ $? -ne 0 ]; then
      print_error "Failed to add remote '$remote_name'."
      exit 1
  fi
  print_success "Remote '$remote_name' added with URL '$ssh_url'."
fi

# --- Step 8: Prepare and Initial Commit ---
print_step "8. Initial Commit"
commit_skipped=false
commit_done=false
# Check for uncommitted changes or untracked files
if git diff --quiet && git diff --staged --quiet && [[ -z $(git ls-files --others --exclude-standard) ]]; then
  print_info "No changes or new files to commit."
  if ask_yes_no "Do you want to create a sample README.md file for the initial commit?" "y"; then
    echo "# $(basename "$(pwd)")" > README.md
    echo "Repository initialized interactively." >> README.md
    git add README.md
    print_success "Sample README.md file created and staged."
  else
    print_warning "No changes to commit. Skipping commit step."
    commit_skipped=true
  fi
else
  print_info "Changes or new files found:"
  git status -s # Show brief status
  if ask_yes_no "Do you want to stage all these changes and new files? (git add .)" "y"; then
      git add .
      print_success "Changes staged."
  else
      print_warning "No changes were staged. Skipping commit step."
      commit_skipped=true
  fi
fi

if [[ "$commit_skipped" != true ]]; then
  commit_message=$(ask_question "Please enter a message for this commit" "Initial commit")
  git commit -m "$commit_message"
  if [ $? -ne 0 ]; then
      print_error "Git commit failed."
      # Check if user identity is missing
      git config user.name > /dev/null 2>&1 || print_warning "You might need to set your Git user name: git config --global user.name \"Your Name\""
      git config user.email > /dev/null 2>&1 || print_warning "You might need to set your Git user email: git config --global user.email \"your@email.com\""
      exit 1
  fi
  print_success "Changes committed with message '$commit_message'."
  commit_done=true
fi

# --- Step 9: Push to GitHub ---
print_step "9. Push to GitHub"
if [[ "$commit_done" != true ]]; then
    print_warning "Since no commit was made, skipping Push step."
    print_info "Script finished."
    exit 0
fi

current_branch=$(git branch --show-current)
if [[ -z "$current_branch" ]]; then
    # If no commits yet or in detached HEAD state
    default_branch=$(git config --get init.defaultBranch || echo "main")
    current_branch=$(ask_question "Could not detect current branch name. What branch do you want to push to?" "$default_branch")
else
    current_branch=$(ask_question "Your current branch is '$current_branch'. Push to this branch? Confirm or correct the branch name" "$current_branch")
fi

print_info "If confirmed, changes will be pushed to branch '$current_branch' on remote '$remote_name'."
if ask_yes_no "Are you ready to push?" "y"; then
  print_info "Pushing to $remote_name/$current_branch and setting upstream..."
  git push --set-upstream "$remote_name" "$current_branch"
  if [ $? -ne 0 ]; then
      print_error "Git push failed."
      print_error "Please check remote settings, GitHub permissions, and SSH connection."
      exit 1
  fi
  print_success "Successfully pushed to $remote_name/$current_branch!"
else
  print_warning "Push operation cancelled."
fi

# --- End ---
print_step "End of Operations"
print_info "Script finished successfully (up to this point)."
exit 0