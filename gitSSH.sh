#!/bin/bash

# --- Helper Functions ---
# (Functions print_step, print_info, print_success, print_warning, print_error, ask_question, ask_yes_no, wait_for_enter remain the same)
print_step() { echo -e "\n\e[1;36m=== $1 ===\e[0m"; }
print_info() { echo -e "\e[34mINFO: $1\e[0m"; }
print_success() { echo -e "\e[32mSUCCESS: $1\e[0m"; }
print_warning() { echo -e "\e[33mWARNING: $1\e[0m"; }
print_error() { echo -e "\e[31mERROR: $1\e[0m" >&2; }
ask_question() { local prompt="$1"; local default_value="$2"; local user_input; if [[ -n "$default_value" ]]; then read -p "$prompt [$default_value]: " user_input; echo "${user_input:-$default_value}"; else read -p "$prompt: " user_input; echo "$user_input"; fi; }
ask_yes_no() { local prompt="$1"; local default="$2"; local answer; while true; do if [[ "$default" == "y" ]]; then read -p "$prompt [Y/n]: " answer; answer=${answer:-y}; elif [[ "$default" == "n" ]]; then read -p "$prompt [y/N]: " answer; answer=${answer:-n}; else read -p "$prompt [y/n]: " answer; fi; case $answer in [Yy]*) return 0;; [Nn]*) return 1;; *) echo "Please answer yes (y) or no (n).";; esac; done; }
wait_for_enter() { echo ""; read -p "Press [Enter] to continue..."; }

# --- Git Menu Functions ---
# (Functions show_status, show_log, add_files, commit_changes, push_changes, pull_changes, manage_branches, merge_branch, reset_branch remain the same)
show_status() { print_step "Git Status"; git status; wait_for_enter; }
show_log() { print_step "Git Log (Last 15 Commits)"; git log --oneline --graph --decorate --all -n 15; wait_for_enter; }
add_files() { print_step "Git Add"; echo "Options:"; echo "  1) Add ALL changes and new files (git add .)"; echo "  2) Add specific file(s)"; echo "  *) Cancel"; local choice; read -p "Enter your choice: " choice; case $choice in 1) if ask_yes_no "Are you sure you want to stage ALL changes and new files?" "y"; then git add .; print_success "All changes staged."; else print_warning "Operation cancelled."; fi ;; 2) local files_to_add; read -p "Enter file/directory names to add (separated by space): " files_to_add; if [[ -n "$files_to_add" ]]; then printf "%s\n" "$files_to_add" | xargs -d '\n' --no-run-if-empty git add --; print_success "Attempted to stage specified files/dirs."; print_info "Check 'git status' to verify."; else print_warning "No files entered. Operation cancelled."; fi ;; *) print_warning "Add operation cancelled.";; esac; wait_for_enter; }
commit_changes() { print_step "Git Commit"; if git diff --staged --quiet; then print_warning "No changes staged for commit. Use 'Git Add' first."; wait_for_enter; return; fi; print_info "Staged changes ready for commit:"; git diff --staged --stat; local commit_message; read -p "Enter commit message: " commit_message; if [[ -z "$commit_message" ]]; then print_warning "Commit cancelled (empty message)."; wait_for_enter; return; fi; git commit -m "$commit_message"; if [ $? -eq 0 ]; then print_success "Changes committed."; else print_error "Commit failed."; fi; wait_for_enter; }
push_changes() { print_step "Git Push"; local current_branch=$(git branch --show-current); local remote_name=$(git config branch.$current_branch.remote || echo "origin"); local remote_url=$(git remote get-url $remote_name 2>/dev/null || echo "unknown"); print_info "Current branch: '$current_branch'. Configured remote: '$remote_name' ($remote_url)"; if [[ -z "$current_branch" ]]; then print_error "Could not determine current branch. Cannot push."; wait_for_enter; return; fi; if ask_yes_no "Confirm push?" "y"; then git push; push_status=$?; if [ $push_status -eq 0 ]; then print_success "Push successful."; else print_error "Push failed (Exit code: $push_status)."; if [[ "$remote_url" == https://* ]]; then print_info "Using HTTPS: Ensure you entered the correct username and Password/Personal Access Token (PAT) when prompted."; fi; print_info "Common issues: New branch? (Use 'git push -u ...'). Remote has changes? ('git pull' first). Rewrote history? ('git push --force' - dangerous!)."; fi; else print_warning "Push cancelled."; fi; wait_for_enter; }
pull_changes() { print_step "Git Pull"; local current_branch=$(git branch --show-current); local remote_name=$(git config branch.$current_branch.remote || echo "origin"); local remote_url=$(git remote get-url $remote_name 2>/dev/null || echo "unknown"); print_info "Current branch: '$current_branch'. Configured remote: '$remote_name' ($remote_url)"; if [[ -z "$current_branch" ]]; then print_error "Could not determine current branch. Cannot pull."; wait_for_enter; return; fi; if ask_yes_no "Confirm pull?" "y"; then git pull; pull_status=$?; if [ $pull_status -eq 0 ]; then print_success "Pull successful."; else print_error "Pull failed (Exit code: $pull_status). Check connection. Resolve conflicts if any."; if [[ "$remote_url" == https://* ]]; then print_info "Using HTTPS: Ensure you entered the correct username and Password/Personal Access Token (PAT) if prompted."; fi; fi; else print_warning "Pull cancelled."; fi; wait_for_enter; }
manage_branches() { print_step "Manage Branches"; echo "Current branches (* indicates current):"; git branch -v; echo ""; echo "Options:"; echo "  1) Create and Checkout (switch to) a new branch (git checkout -b <name>)"; echo "  2) Create a new branch without switching (git branch <name>)"; echo "  3) Checkout (switch to) an existing branch (git checkout <name>)"; echo "  4) Delete a local branch (use with caution!)"; echo "  *) Back to main menu"; local choice; read -p "Enter your choice: " choice; local branch_name; case $choice in 1) read -p "Enter name for the new branch to create and checkout: " branch_name; if [[ -n "$branch_name" ]]; then git checkout -b "$branch_name"; if [ $? -ne 0 ]; then print_error "Failed to create and checkout branch '$branch_name'."; fi; else print_warning "No branch name entered."; fi ;; 2) read -p "Enter name for the new branch to create: " branch_name; if [[ -n "$branch_name" ]]; then git branch "$branch_name"; if [ $? -eq 0 ]; then print_success "Branch '$branch_name' created."; else print_error "Failed to create branch '$branch_name'."; fi; else print_warning "No branch name entered."; fi ;; 3) read -p "Enter the name of the branch to checkout: " branch_name; if [[ -n "$branch_name" ]]; then git checkout "$branch_name"; if [ $? -ne 0 ]; then print_error "Checkout failed."; fi; else print_warning "No branch name entered."; fi ;; 4) read -p "Enter the name of the LOCAL branch to delete: " branch_name; if [[ -n "$branch_name" ]]; then local current_branch_check=$(git branch --show-current); if [[ "$current_branch_check" == "$branch_name" ]]; then print_error "Cannot delete current branch."; elif ask_yes_no "DELETE local branch '$branch_name'? Are you sure?" "n"; then if ask_yes_no "Use safe delete (-d)? (Requires branch to be merged). Choose 'n' for force delete (-D)." "y"; then git branch -d "$branch_name"; else git branch -D "$branch_name"; fi; if [ $? -eq 0 ]; then print_success "Branch '$branch_name' deleted."; else print_error "Failed to delete branch."; fi; else print_warning "Delete cancelled."; fi; else print_warning "No branch name entered."; fi ;; *) print_info "Returning to main menu.";; esac; wait_for_enter; }
merge_branch() { print_step "Merge Branch into Current"; local current_branch=$(git branch --show-current); if [[ -z "$current_branch" ]]; then print_error "Cannot determine current branch."; wait_for_enter; return; fi; print_info "You are on branch: '$current_branch'."; echo "Available local branches to merge from:"; git branch | grep -v "^\* $current_branch$"; local branch_to_merge; read -p "Enter the name of the branch to merge into '$current_branch': " branch_to_merge; if [[ -z "$branch_to_merge" ]]; then print_warning "Merge cancelled."; wait_for_enter; return; fi; if [[ "$branch_to_merge" == "$current_branch" ]]; then print_error "Cannot merge branch into itself."; wait_for_enter; return; fi; if ! git rev-parse --verify "$branch_to_merge" > /dev/null 2>&1; then print_error "Branch '$branch_to_merge' not found locally."; wait_for_enter; return; fi; if ask_yes_no "Merge branch '$branch_to_merge' into current branch '$current_branch'?" "y"; then print_info "Attempting merge..."; git merge "$branch_to_merge"; merge_status=$?; if [ $merge_status -eq 0 ]; then print_success "Merge successful."; else print_error "Merge failed (Exit code: $merge_status). Potential conflicts detected."; print_warning "Please resolve conflicts manually: 'git status', edit files, 'git add <files>', 'git commit'."; print_warning "Or run 'git merge --abort'."; fi; else print_warning "Merge cancelled."; fi; wait_for_enter; }
reset_branch() { print_step "Reset Current Branch to Specific Commit"; local current_branch=$(git branch --show-current); if [[ -z "$current_branch" ]]; then print_error "Cannot determine current branch."; wait_for_enter; return; fi; print_warning "!!! DANGER ZONE !!!"; print_warning "'git reset --hard' discards ALL local changes (staged and unstaged) and moves branch pointer."; print_warning "This CANNOT be easily undone for local changes."; print_warning "If resetting past pushed commits, you WILL need 'git push --force' later (dangerous for collaborators)."; echo ""; print_info "Recent commits on branch '$current_branch':"; git log --oneline --graph -n 20 "$current_branch"; echo ""; local commit_hash; read -p "Enter the commit hash (e.g., a1b2c3d) to reset '$current_branch' to: " commit_hash; if [[ -z "$commit_hash" ]]; then print_warning "Reset cancelled."; wait_for_enter; return; fi; if ! git rev-parse --verify "$commit_hash^{commit}" > /dev/null 2>&1; then print_error "Invalid commit hash: '$commit_hash'."; wait_for_enter; return; fi; print_warning "Resetting '$current_branch' to '$commit_hash' will DESTROY local changes after it."; if ask_yes_no "First confirmation: Proceed with reset?" "n"; then if ask_yes_no "Second confirmation: REALLY reset '$current_branch' to '$commit_hash'?" "n"; then print_info "Executing: git reset --hard $commit_hash"; git reset --hard "$commit_hash"; if [ $? -eq 0 ]; then print_success "Branch '$current_branch' reset to $commit_hash."; print_warning "Remember: 'git push --force' might be needed if history was rewritten."; else print_error "git reset --hard failed."; fi; else print_warning "Reset cancelled."; fi; else print_warning "Reset cancelled."; fi; wait_for_enter; }

# --- Function to Show Main Git Menu ---
show_git_menu() {
    print_step "Git Operations Menu"
    PS3=$'\n'"Enter your choice (or Ctrl+C to exit script): "
    options=(
        "Show Status"                 # git status
        "Show Log (Simple)"           # git log --oneline...
        "Add Changes"                 # git add . OR git add <files>
        "Commit Staged Changes"       # git commit -m "..."
        "Push to Remote"              # git push
        "Pull from Remote"            # git pull
        "Manage Branches"             # Submenu: list, create, checkout, delete
        "Merge Branch into Current"   # git merge <branch>
        "Reset Current Branch to Commit (DANGEROUS)" # git reset --hard <commit>
        "Exit Script"
    )
    select opt in "${options[@]}"
    do
        if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
           print_error "Current directory is not a Git repository anymore. Exiting menu."
           break
        fi
        case $opt in
            "Show Status") show_status ;;
            "Show Log (Simple)") show_log ;;
            "Add Changes") add_files ;;
            "Commit Staged Changes") commit_changes ;;
            "Push to Remote") push_changes ;;
            "Pull from Remote") pull_changes ;;
            "Manage Branches") manage_branches ;;
            "Merge Branch into Current") merge_branch ;;
            "Reset Current Branch to Commit (DANGEROUS)") reset_branch ;;
            "Exit Script") print_info "Exiting script."; break ;;
            *) echo "Invalid option $REPLY" ;;
        esac
    done
}

# --- Main Script Logic ---

# --- STEP 1: Prerequisites ---
print_step "1. Checking Prerequisites"
command -v git >/dev/null 2>&1 || { print_error "Git is not installed."; exit 1; }
# SSH tools are only checked if SSH method is chosen later
print_success "Git found."

# --- STEP 2: Repository Path ---
print_step "2. Set Local Repository Path"
repo_path=$(ask_question "Enter the full path to your local Git repository" "$(pwd)")
if [[ ! -d "$repo_path" ]]; then print_error "Invalid directory path."; exit 1; fi
cd "$repo_path" || { print_error "Failed to change to directory $repo_path."; exit 1; }
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
   print_error "Path '$repo_path' is not a valid Git repository. Run 'git init' first."; exit 1;
fi
print_success "Operating inside repository: $(pwd)"

# --- STEP 3: Choose Authentication Method ---
print_step "3. Choose Authentication Method"
AUTH_METHOD=""
echo "Select the authentication method for connecting to the remote repository:"
echo "  1) SSH Key (Recommended)"
echo "  2) HTTPS with Personal Access Token (PAT)"
echo "  3) HTTPS with Username/Password (Discouraged, may not work on all platforms like GitHub)"
local auth_choice
read -p "Enter your choice (1, 2, or 3): " auth_choice
case $auth_choice in
    1) AUTH_METHOD="ssh" ;;
    2) AUTH_METHOD="https_token" ;;
    3) AUTH_METHOD="https_password" ;;
    *) print_error "Invalid choice. Exiting."; exit 1 ;;
esac
print_info "Selected method: $AUTH_METHOD"

# --- STEP 4: Authentication Setup ---
print_step "4. Authentication Setup ($AUTH_METHOD)"
setup_ok=false
if [[ "$AUTH_METHOD" == "ssh" ]]; then
    # --- SSH Setup Path ---
    command -v ssh >/dev/null 2>&1 || { print_error "OpenSSH Client not found (needed for SSH)."; exit 1; }
    command -v ssh-keygen >/dev/null 2>&1 || { print_error "ssh-keygen not found (needed for SSH)."; exit 1; }
    command -v ssh-agent >/dev/null 2>&1 || { print_error "ssh-agent not found (needed for SSH)."; exit 1; }
    command -v ssh-add >/dev/null 2>&1 || { print_error "ssh-add not found (needed for SSH)."; exit 1; }
    print_success "Required SSH tools found."

    github_email=$(ask_question "Enter the email associated with your Git Host account (GitHub/GitLab etc.)")
    default_ssh_key_path="$HOME/.ssh/id_ed25519"
    ssh_key_path="$default_ssh_key_path"
    generate_new_key=false # Flag to track if we generated a key

    if [ -f "${ssh_key_path}.pub" ]; then
        print_info "Existing SSH key found: ${ssh_key_path}"
        if ! ask_yes_no "Use this existing key?" "y"; then
            ssh_key_path=$(ask_question "Enter new path or same path to overwrite" "$default_ssh_key_path")
            if [ -f "$ssh_key_path" ] || [ -f "${ssh_key_path}.pub" ]; then
                if ! ask_yes_no "Overwrite existing key at '$ssh_key_path'?" "n"; then print_error "Operation cancelled."; exit 1; fi
                rm -f "$ssh_key_path" "${ssh_key_path}.pub"
            fi
            generate_new_key=true
        fi
    else
        print_info "No SSH key found at default path."
        if ! ask_yes_no "Create a new SSH key now ($ssh_key_path)?" "y"; then print_error "SSH key required. Exiting."; exit 1; fi
        generate_new_key=true
    fi

    if $generate_new_key; then
        print_info "Generating new ed25519 SSH key..."
        echo "You can press Enter to accept the default file location."
        echo "You will be asked for a passphrase to secure the key (recommended)."
        ssh-keygen -t ed25519 -C "$github_email" -f "$ssh_key_path"
        if [ $? -ne 0 ]; then print_error "SSH key generation failed."; exit 1; fi
        print_success "New SSH key generated: $ssh_key_path"
        mkdir -p ~/.ssh; chmod 700 ~/.ssh; chmod 600 "$ssh_key_path"; chmod 644 "${ssh_key_path}.pub"
    fi

    print_info "Your PUBLIC SSH key (${ssh_key_path}.pub):"
    echo "---------------------------------------------"; echo -e "\e[36m"; cat "${ssh_key_path}.pub"; echo -e "\e[0m"; echo "---------------------------------------------"
    print_warning "--> ACTION REQUIRED <--"
    print_warning "1. Copy the public key text above."
    print_warning "2. Go to your Git hosting provider (GitHub, GitLab, etc.)."
    print_warning "3. Find the SSH Keys section in your account settings."
    print_warning "4. Add the copied key as a new SSH key."
    read -p ">>> Press [Enter] after adding the key to your Git host..."

    # SSH Agent
    print_info "Starting/Checking ssh-agent..."
    ssh-add -l > /dev/null 2>&1 || eval "$(ssh-agent -s)" > /dev/null
    print_info "Adding SSH key to agent (enter passphrase if prompted)..."
    ssh-add "$ssh_key_path"
    if [ $? -ne 0 ]; then print_error "Failed to add key to agent. Correct passphrase?"; exit 1; fi # Exit if agent fails
    print_success "Key added to agent."

    # Test Connection
    git_host=$(ask_question "Enter the Git host domain to test SSH connection (e.g., github.com, gitlab.com)" "github.com")
    print_info "Testing SSH connection to $git_host..."
    ssh -T "git@${git_host}"
    ssh_exit_code=$?
    if [ $ssh_exit_code -eq 1 ]; then
        print_success "SSH connection test successful!"
        setup_ok=true
    else
        print_error "SSH connection test failed (Exit code: $ssh_exit_code)."
        print_error "Ensure key was added correctly to $git_host and agent, and passphrase was correct."
        if ! ask_yes_no "Continue anyway (maybe test was wrong host, or host key needs confirmation)?" "n"; then exit 1; fi
        setup_ok=true # Allow proceeding, but setup might still fail later
    fi

elif [[ "$AUTH_METHOD" == "https_token" ]]; then
    # --- HTTPS Token Setup Path ---
    print_info "Using HTTPS with Personal Access Token (PAT)."
    print_warning "When Git prompts for 'Password', enter your PAT, not your account password."
    print_info "Generate PATs with appropriate scopes (e.g., 'repo' on GitHub, 'read_repository'/'write_repository' on GitLab) in your Git host's account/developer settings."
    if ask_yes_no "Do you want Git to cache credentials temporarily (e.g., 15 mins)?" "y"; then
        git config credential.helper cache # Use local config by default
        # git config --global credential.helper cache # Or global
        print_success "Git credential caching (temporary) enabled for this repository."
    fi
    setup_ok=true

elif [[ "$AUTH_METHOD" == "https_password" ]]; then
     # --- HTTPS Password Setup Path ---
    print_warning "Using HTTPS with account Username/Password."
    print_warning "!!! THIS METHOD IS STRONGLY DISCOURAGED AND LESS SECURE !!!"
    print_warning "Most providers (like GitHub) have disabled password authentication for Git operations."
    print_warning "It is recommended to use SSH or Personal Access Tokens (PATs) instead."
    if ! ask_yes_no "Are you sure you want to proceed using your account password?" "n"; then
        print_error "Operation cancelled by user due to security concerns."
        exit 1
    fi
    print_info "Proceeding with Username/Password (if the provider still allows it)."
    print_info "Git will prompt for your username and account password when needed."
     if ask_yes_no "Do you want Git to cache credentials temporarily (e.g., 15 mins)?" "y"; then
        git config credential.helper cache # Local config
        print_success "Git credential caching (temporary) enabled for this repository."
    fi
    setup_ok=true
fi

# --- STEP 5: Configure Git Remote ---
if ! $setup_ok; then
    print_error "Authentication setup failed or was incomplete. Cannot configure remote."
    exit 1
fi

print_step "5. Configure Git Remote"
remote_name=$(ask_question "Enter the remote name (usually 'origin')" "origin")
url_prompt=""
example_url=""
url_type_for_validation="" # ssh or https

if [[ "$AUTH_METHOD" == "ssh" ]]; then
    url_prompt="Enter the SSH URL (e.g., git@hostname.com:user/repo.git):"
    example_url="git@github.com:YOUR_USER/YOUR_REPO.git"
    url_type_for_validation="ssh"
else # https_token or https_password
    url_prompt="Enter the HTTPS URL (e.g., https://hostname.com/user/repo.git):"
    example_url="https://github.com/YOUR_USER/YOUR_REPO.git"
    url_type_for_validation="https"
fi
print_info "Example URL format: $example_url"
remote_url=$(ask_question "$url_prompt")

# Basic validation based on method
valid_url=false
if [[ "$url_type_for_validation" == "ssh" && "$remote_url" == git@* && "$remote_url" == *.git ]]; then
    valid_url=true
elif [[ "$url_type_for_validation" == "https" && "$remote_url" == https://* && "$remote_url" == *.git ]]; then
     valid_url=true
fi

if ! $valid_url; then
    print_warning "The entered URL does not match the expected format for $url_type_for_validation. Please double-check."
    if ! ask_yes_no "Continue with this URL anyway?" "n"; then exit 1; fi
fi

existing_url=$(git remote get-url "$remote_name" 2>/dev/null)
remote_action_ok=false
if [[ -n "$existing_url" ]]; then
  print_info "Remote '$remote_name' already exists: '$existing_url'"
  if [[ "$existing_url" != "$remote_url" ]]; then
    if ask_yes_no "Update URL for remote '$remote_name' to '$remote_url'?" "y"; then
      git remote set-url "$remote_name" "$remote_url" && remote_action_ok=true
      if $remote_action_ok; then print_success "Remote '$remote_name' updated."; else print_error "Failed to update remote."; fi
    else
      print_info "Remote URL not changed. Using existing URL for further steps."
      remote_action_ok=true # Continue with existing remote
    fi
  else
     print_info "Remote '$remote_name' URL is already correct."
     remote_action_ok=true
  fi
else
  print_info "Adding new remote '$remote_name' with URL '$remote_url'..."
  git remote add "$remote_name" "$remote_url" && remote_action_ok=true
  if $remote_action_ok; then print_success "Remote '$remote_name' added."; else print_error "Failed to add remote."; fi
fi

if ! $remote_action_ok; then
    print_error "Remote configuration failed. Exiting."
    exit 1
fi

# --- STEP 6: Initial Commit/Push (Optional) ---
# (This part remains optional, mainly for new repos)
print_step "6. Initial Commit & Push (Optional)"
if ! git rev-parse --verify HEAD > /dev/null 2>&1; then
     print_info "This repository has no commits yet."
     if ask_yes_no "Do you want to perform an initial commit and push now?" "y"; then
         # --- Placeholder for initial commit/push logic ---
         # 1. Create/Add a file (e.g., README.md)
         echo "# $(basename "$repo_path")" > README.md
         git add README.md
         # 2. Commit
         initial_commit_msg=$(ask_question "Enter message for initial commit" "Initial commit")
         git commit -m "$initial_commit_msg"
         commit_status=$?
         # 3. Push
         if [ $commit_status -eq 0 ]; then
             initial_branch=$(git branch --show-current || git config --get init.defaultBranch || echo "main")
             print_info "Attempting initial push of branch '$initial_branch' to remote '$remote_name'..."
             git push --set-upstream "$remote_name" "$initial_branch"
             if [ $? -ne 0 ]; then print_error "Initial push failed."; else print_success "Initial push successful."; fi
         else
             print_error "Initial commit failed. Skipping push.";
         fi
         # --- End Placeholder ---
     fi
else
    print_info "Repository already has commits. Skipping initial commit/push step."
fi


# --- STEP 7: Show Git Menu ---
print_step "7. Proceeding to Git Operations Menu"
show_git_menu


# --- End ---
print_info "Exiting Git Helper Script."
exit 0