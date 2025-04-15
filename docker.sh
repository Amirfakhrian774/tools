#!/bin/bash

# --- Helper Functions ---
# (Using the same helper functions as before for printing messages)
print_step() { echo -e "\n\e[1;36m=== $1 ===\e[0m"; }
print_info() { echo -e "\e[34mINFO: $1\e[0m"; }
print_success() { echo -e "\e[32mSUCCESS: $1\e[0m"; }
print_warning() { echo -e "\e[33mWARNING: $1\e[0m"; }
print_error() { echo -e "\e[31mERROR: $1\e[0m" >&2; }
ask_question() { local prompt="$1"; local default_value="$2"; local user_input; if [[ -n "$default_value" ]]; then read -p "$prompt [$default_value]: " user_input; echo "${user_input:-$default_value}"; else read -p "$prompt: " user_input; echo "$user_input"; fi; }
ask_yes_no() { local prompt="$1"; local default="$2"; local answer; while true; do if [[ "$default" == "y" ]]; then read -p "$prompt [Y/n]: " answer; answer=${answer:-y}; elif [[ "$default" == "n" ]]; then read -p "$prompt [y/N]: " answer; answer=${answer:-n}; else read -p "$prompt [y/n]: " answer; fi; case $answer in [Yy]*) return 0;; [Nn]*) return 1;; *) echo "Please answer yes (y) or no (n).";; esac; done; }
wait_for_enter() { echo ""; read -p "Press [Enter] to continue..."; }

# --- Prerequisite Check ---
check_prereqs() {
    print_step "Checking Prerequisites"
    if ! command -v docker &> /dev/null; then
        print_error "Docker command not found. Please install Docker."
        exit 1
    fi
    print_success "Docker command found."
    # Check for docker-compose (optional, only needed for compose commands)
    if ! command -v docker-compose &> /dev/null; then
        # Check for 'docker compose' (newer plugin syntax)
        if ! docker compose version &> /dev/null; then
             print_warning "docker-compose or 'docker compose' plugin not found. Compose commands will fail."
             DOCKER_COMPOSE_CMD="" # Indicate compose is not available
        else
             print_success "'docker compose' plugin found."
             DOCKER_COMPOSE_CMD="docker compose" # Use new syntax
        fi
    else
        print_success "docker-compose found."
        DOCKER_COMPOSE_CMD="docker-compose" # Use old syntax
    fi
}

# --- Docker Operation Functions ---

list_running_containers() {
    print_step "List Running Containers"
    docker ps
    wait_for_enter
}

list_all_containers() {
    print_step "List All Containers (Running and Stopped)"
    docker ps -a
    wait_for_enter
}

view_container_logs() {
    print_step "View Container Logs"
    print_info "Available Containers (Running and Stopped):"
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"
    local container_id
    read -p "Enter Container ID or Name to view logs: " container_id
    if [[ -z "$container_id" ]]; then print_warning "No container specified."; wait_for_enter; return; fi

    local follow_logs="n"
    local tail_count=""
    if ask_yes_no "Follow logs (-f)?" "n"; then follow_logs="y"; fi
    read -p "Show only last N lines? (e.g., 100, leave blank for all): " tail_count

    local cmd="docker logs"
    if [[ "$follow_logs" == "y" ]]; then cmd+=" -f"; fi
    if [[ -n "$tail_count" && "$tail_count" =~ ^[0-9]+$ ]]; then cmd+=" --tail $tail_count"; fi
    cmd+=" $container_id"

    print_info "Running: $cmd"
    # Use eval maybe risky, construct command carefully
    if [[ "$follow_logs" == "y" ]]; then
        docker logs -f ${tail_count:+--tail $tail_count} "$container_id" # + notation adds arg only if var is set
    else
        docker logs ${tail_count:+--tail $tail_count} "$container_id"
        wait_for_enter
    fi
    # If following, Ctrl+C will exit, no need for wait_for_enter
}

stop_containers() {
    print_step "Stop Running Container(s)"
    print_info "Running Containers:"
    docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"
    local container_ids
    read -p "Enter Container ID(s) or Name(s) to stop (space-separated): " container_ids
    if [[ -z "$container_ids" ]]; then print_warning "No container(s) specified."; wait_for_enter; return; fi

    if ask_yes_no "Stop container(s): $container_ids ?" "y"; then
        echo "$container_ids" | xargs --no-run-if-empty docker stop
        print_success "Stop command issued for: $container_ids"
    else
        print_warning "Operation cancelled."
    fi
    wait_for_enter
}

start_containers() {
    print_step "Start Stopped Container(s)"
    print_info "Stopped Containers:"
    docker ps -a --filter status=exited --filter status=created --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"
    local container_ids
    read -p "Enter Container ID(s) or Name(s) to start (space-separated): " container_ids
    if [[ -z "$container_ids" ]]; then print_warning "No container(s) specified."; wait_for_enter; return; fi

    if ask_yes_no "Start container(s): $container_ids ?" "y"; then
        echo "$container_ids" | xargs --no-run-if-empty docker start
        print_success "Start command issued for: $container_ids"
    else
        print_warning "Operation cancelled."
    fi
    wait_for_enter
}

restart_containers() {
    print_step "Restart Running Container(s)"
    print_info "Running Containers:"
    docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"
    local container_ids
    read -p "Enter Container ID(s) or Name(s) to restart (space-separated): " container_ids
    if [[ -z "$container_ids" ]]; then print_warning "No container(s) specified."; wait_for_enter; return; fi

    if ask_yes_no "Restart container(s): $container_ids ?" "y"; then
        echo "$container_ids" | xargs --no-run-if-empty docker restart
        print_success "Restart command issued for: $container_ids"
    else
        print_warning "Operation cancelled."
    fi
    wait_for_enter
}

remove_containers() {
    print_step "Remove Container(s) (Keeps Image)"
    print_info "Available Containers (Running and Stopped):"
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"
    local container_ids
    read -p "Enter Container ID(s) or Name(s) to remove (space-separated): " container_ids
    if [[ -z "$container_ids" ]]; then print_warning "No container(s) specified."; wait_for_enter; return; fi

    print_warning "This will permanently remove the selected container(s) and their associated anonymous volumes (-v flag)."
    if ask_yes_no "REMOVE container(s): $container_ids ?" "n"; then
        # Use -f to force remove running containers, -v to remove anonymous volumes
        echo "$container_ids" | xargs --no-run-if-empty docker rm -fv
        print_success "Remove command issued for: $container_ids"
    else
        print_warning "Operation cancelled."
    fi
    wait_for_enter
}

execute_in_container() {
    print_step "Execute Command in Running Container"
    print_info "Running Containers:"
    docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}"
    local container_id command_to_run
    read -p "Enter Container ID or Name to execute command in: " container_id
    if [[ -z "$container_id" ]]; then print_warning "No container specified."; wait_for_enter; return; fi
    read -p "Enter command to run (e.g., 'bash', 'ls -l /app'): " command_to_run
    if [[ -z "$command_to_run" ]]; then print_warning "No command specified."; wait_for_enter; return; fi

    print_info "Running 'docker exec -it $container_id $command_to_run'..."
    docker exec -it "$container_id" $command_to_run
    # No wait_for_enter needed as exec is interactive or finishes
}

inspect_object() {
    print_step "Inspect Docker Object"
    local object_id
    read -p "Enter Container, Image, Volume, or Network ID/Name to inspect: " object_id
     if [[ -z "$object_id" ]]; then print_warning "No ID/Name specified."; wait_for_enter; return; fi
     docker inspect "$object_id"
     wait_for_enter
}

list_images() {
    print_step "List Docker Images"
    docker images
    wait_for_enter
}

remove_images() {
    print_step "Remove Docker Image(s)"
    print_info "Available Images:"
    docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}"
    local image_ids
    read -p "Enter Image ID(s) or REPOSITORY:TAG to remove (space-separated): " image_ids
    if [[ -z "$image_ids" ]]; then print_warning "No image(s) specified."; wait_for_enter; return; fi

    print_warning "This will permanently remove the selected image(s)."
    print_warning "Ensure no containers are using them (stopped containers might still depend on them)."
    if ask_yes_no "REMOVE image(s): $image_ids ?" "n"; then
        echo "$image_ids" | xargs --no-run-if-empty docker rmi
        print_success "Remove image command issued for: $image_ids"
    else
        print_warning "Operation cancelled."
    fi
    wait_for_enter
}

list_networks() {
    print_step "List Docker Networks"
    docker network ls
    wait_for_enter
}

list_volumes() {
    print_step "List Docker Volumes"
    docker volume ls
    wait_for_enter
}

# --- Docker Compose Functions (Operate in Current Directory) ---

compose_up() {
    print_step "Docker Compose Up (in $(pwd))"
    if [[ -z "$DOCKER_COMPOSE_CMD" ]]; then print_error "docker-compose / docker compose not found."; wait_for_enter; return; fi
    if [[ ! -f "docker-compose.yml" && ! -f "docker-compose.yaml" ]]; then
        print_error "No 'docker-compose.yml' or 'docker-compose.yaml' found in current directory."; wait_for_enter; return; fi

    if ask_yes_no "Run '$DOCKER_COMPOSE_CMD up -d' in this directory?" "y"; then
        $DOCKER_COMPOSE_CMD up -d
        print_success "Compose up command executed."
    else
        print_warning "Operation cancelled."
    fi
    wait_for_enter
}

compose_down() {
    print_step "Docker Compose Down (in $(pwd))"
     if [[ -z "$DOCKER_COMPOSE_CMD" ]]; then print_error "docker-compose / docker compose not found."; wait_for_enter; return; fi
    if [[ ! -f "docker-compose.yml" && ! -f "docker-compose.yaml" ]]; then
        print_error "No 'docker-compose.yml' or 'docker-compose.yaml' found in current directory."; wait_for_enter; return; fi

    local remove_volumes_flag=""
    if ask_yes_no "Remove named volumes declared in 'volumes' section? (-v flag)" "n"; then
        remove_volumes_flag="-v"
    fi

    if ask_yes_no "Run '$DOCKER_COMPOSE_CMD down $remove_volumes_flag' in this directory?" "y"; then
        $DOCKER_COMPOSE_CMD down $remove_volumes_flag
        print_success "Compose down command executed."
    else
        print_warning "Operation cancelled."
    fi
    wait_for_enter
}

compose_logs() {
    print_step "Docker Compose Logs (in $(pwd))"
    if [[ -z "$DOCKER_COMPOSE_CMD" ]]; then print_error "docker-compose / docker compose not found."; wait_for_enter; return; fi
    if [[ ! -f "docker-compose.yml" && ! -f "docker-compose.yaml" ]]; then
        print_error "No 'docker-compose.yml' or 'docker-compose.yaml' found in current directory."; wait_for_enter; return; fi

    local follow_logs="n"
    local tail_count=""
    if ask_yes_no "Follow logs (-f)?" "n"; then follow_logs="y"; fi
    read -p "Show only last N lines? (e.g., 100, leave blank for all): " tail_count

    local cmd="$DOCKER_COMPOSE_CMD logs"
    if [[ "$follow_logs" == "y" ]]; then cmd+=" -f"; fi
    if [[ -n "$tail_count" && "$tail_count" =~ ^[0-9]+$ ]]; then cmd+=" --tail $tail_count"; fi

    print_info "Running: $cmd"
    if [[ "$follow_logs" == "y" ]]; then
        $DOCKER_COMPOSE_CMD logs -f ${tail_count:+--tail $tail_count}
    else
        $DOCKER_COMPOSE_CMD logs ${tail_count:+--tail $tail_count}
        wait_for_enter
    fi
     # If following, Ctrl+C will exit
}

compose_build() {
    print_step "Docker Compose Build (in $(pwd))"
    if [[ -z "$DOCKER_COMPOSE_CMD" ]]; then print_error "docker-compose / docker compose not found."; wait_for_enter; return; fi
    if [[ ! -f "docker-compose.yml" && ! -f "docker-compose.yaml" ]]; then
        print_error "No 'docker-compose.yml' or 'docker-compose.yaml' found in current directory."; wait_for_enter; return; fi

    local build_opts=""
    if ask_yes_no "Force build without cache (--no-cache)?" "n"; then build_opts+=" --no-cache"; fi
    if ask_yes_no "Pull newer base images before build (--pull)?" "n"; then build_opts+=" --pull"; fi


    if ask_yes_no "Run '$DOCKER_COMPOSE_CMD build $build_opts' in this directory?" "y"; then
        $DOCKER_COMPOSE_CMD build $build_opts
        print_success "Compose build command executed."
    else
        print_warning "Operation cancelled."
    fi
    wait_for_enter
}


compose_pull() {
    print_step "Docker Compose Pull (in $(pwd))"
    if [[ -z "$DOCKER_COMPOSE_CMD" ]]; then print_error "docker-compose / docker compose not found."; wait_for_enter; return; fi
    if [[ ! -f "docker-compose.yml" && ! -f "docker-compose.yaml" ]]; then
        print_error "No 'docker-compose.yml' or 'docker-compose.yaml' found in current directory."; wait_for_enter; return; fi

    if ask_yes_no "Run '$DOCKER_COMPOSE_CMD pull' to pull service images?" "y"; then
        $DOCKER_COMPOSE_CMD pull
        print_success "Compose pull command executed."
    else
        print_warning "Operation cancelled."
    fi
    wait_for_enter
}


# --- Pruning Functions ---
prune_resources_menu() {
    print_step "Prune System Resources"
    print_warning "Pruning permanently removes unused Docker objects."

    PS3=$'\n'"Select resource type to prune: "
     options=(
        "Stopped Containers (`docker container prune`)"
        "Unused Networks (`docker network prune`)"
        "Dangling Images (`docker image prune`)"
        "Unused Images (All unused, not just dangling) (`docker image prune -a`)"
        "Unused Volumes (`docker volume prune`) - CAUTION: Data loss possible!"
        "**DANGEROUS:** Full System Prune (All above + build cache) (`docker system prune -a --volumes`)"
        "Back to Main Menu"
    )
    select opt in "${options[@]}"
    do
        case $opt in
            "Stopped Containers (`docker container prune`)")
                if ask_yes_no "Prune stopped containers?" "n"; then docker container prune -f; fi
                ;;
            "Unused Networks (`docker network prune`)")
                 if ask_yes_no "Prune unused networks?" "n"; then docker network prune -f; fi
                ;;
            "Dangling Images (`docker image prune`)")
                 if ask_yes_no "Prune dangling images?" "n"; then docker image prune -f; fi
                ;;
            "Unused Images (All unused, not just dangling) (`docker image prune -a`)")
                 if ask_yes_no "Prune ALL unused images (not just dangling)?" "n"; then docker image prune -a -f; fi
                ;;
             "Unused Volumes (`docker volume prune`) - CAUTION: Data loss possible!")
                 print_warning "!!! Removing unused volumes can lead to data loss if a stopped container intended to reuse it !!!"
                 if ask_yes_no "Prune unused volumes? ARE YOU SURE?" "n"; then docker volume prune -f; fi
                ;;
             "**DANGEROUS:** Full System Prune (All above + build cache) (`docker system prune -a --volumes`)")
                 print_warning "!!! THIS WILL REMOVE ALL STOPPED CONTAINERS, UNUSED NETWORKS, DANGLING AND UNUSED IMAGES, UNUSED VOLUMES, AND BUILD CACHE !!!"
                 if ask_yes_no "Perform full system prune? First confirmation." "n"; then
                    if ask_yes_no "REALLY perform full system prune? FINAL confirmation." "n"; then
                        docker system prune -a -f --volumes
                    else
                        print_warning "Full prune cancelled."
                    fi
                 else
                    print_warning "Full prune cancelled."
                 fi
                ;;
            "Back to Main Menu")
                break
                ;;
            *)
                echo "Invalid option $REPLY"
                ;;
        esac
        # Don't wait for enter here, let the prune submenu redisplay
    done
    # Wait after exiting the submenu
    wait_for_enter
}


# --- Main Menu Function ---
show_main_menu() {
    print_step "Docker & Compose Management Menu"
    PS3=$'\n'"Enter your choice: "
    mapfile -t options < <(printf "%s\n" \
        "List Running Containers" \
        "List All Containers" \
        "View Container Logs" \
        "Stop Container(s)" \
        "Start Container(s)" \
        "Restart Container(s)" \
        "Remove Container(s) (Keeps Image)" \
        "Execute Command in Container" \
        "Inspect Docker Object (Container/Image/Volume/Network)" \
        "List Images" \
        "Remove Image(s)" \
        "List Networks" \
        "List Volumes" \
        "Compose: Up (-d)" \
        "Compose: Down (-v)" \
        "Compose: Logs" \
        "Compose: Build" \
        "Compose: Pull" \
        "Prune System Resources..." \
        "Exit Script" \
    )

    select opt in "${options[@]}"
    do
        case $opt in
            "List Running Containers") list_running_containers ;;
            "List All Containers") list_all_containers ;;
            "View Container Logs") view_container_logs ;;
            "Stop Container(s)") stop_containers ;;
            "Start Container(s)") start_containers ;;
            "Restart Container(s)") restart_containers ;;
            "Remove Container(s) (Keeps Image)") remove_containers ;;
            "Execute Command in Container") execute_in_container ;;
            "Inspect Docker Object (Container/Image/Volume/Network)") inspect_object ;;
            "List Images") list_images ;;
            "Remove Image(s)") remove_images ;;
            "List Networks") list_networks ;;
            "List Volumes") list_volumes ;;
            "Compose: Up (-d)") compose_up ;;
            "Compose: Down (-v)") compose_down ;;
            "Compose: Logs") compose_logs ;;
            "Compose: Build") compose_build ;;
            "Compose: Pull") compose_pull ;;
            "Prune System Resources...") prune_resources_menu ;;
            "Exit Script") print_info "Exiting."; break ;;
            *) echo "Invalid option $REPLY" ;;
        esac
    done
}

# --- Script Execution ---
check_prereqs
show_main_menu

exit 0