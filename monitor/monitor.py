import psutil
import time
import datetime
import logging
import os
import csv
from collections import defaultdict
import sys # Needed for sys.executable, sys.exit, and sys.argv
import ctypes # Needed for Windows API calls (IsUserAnAdmin, ShellExecuteW)

# --- تنظیمات ---
# Determine the script's or executable's directory
# This is a robust way that works for both .py execution and PyInstaller --onefile .exe
if getattr(sys, 'frozen', False):
    # Running as a PyInstaller executable
    script_directory = os.path.dirname(os.path.abspath(sys.argv[0]))
else:
    # Running as a normal Python script
    script_directory = os.path.dirname(os.path.abspath(__file__))

# Define file paths relative to the script/executable directory
LOG_FILENAME = os.path.join(script_directory, 'script_operational_log.txt')
SNAPSHOT_FILENAME_TXT = os.path.join(script_directory, "task_manager_snapshot.txt")
SYSTEM_SUMMARY_FILENAME = os.path.join(script_directory, "system_summary.csv") # Name is defined, but writing is conditional
INDENT_STRING = "  "

# --- تنظیمات جدید ---
ENABLE_SYSTEM_SUMMARY_CSV = False # <<< Set to True if you want the system_summary.csv file

# --- تنظیم لاگر ---
# Configure logger only if it hasn't been configured before (prevents duplicate handlers if relaunched)
if not logging.getLogger().handlers:
    logging.basicConfig(filename=LOG_FILENAME,
                        level=logging.INFO,
                        format='%(asctime)s - %(levelname)s - %(message)s',
                        filemode='a')
    # Optional: Suppress noisy logs from psutil itself below ERROR level
    try:
        logging.getLogger('psutil').setLevel(logging.ERROR)
    except Exception:
         pass # Ignore if logger name 'psutil' is not yet registered


# --- متغیرهای سراسری (برای نگهداری وضعیت بین Snapshot ها) ---
previous_io_counters = {} # Stores psutil.Process.io_counters() from the PREVIOUS snapshot
process_objects_cache = {} # Stores psutil.Process objects for reuse
current_snapshot_data = {} # Stores processed data (CPU%, Mem, IO Delta) for the CURRENT snapshot


# --- توابع کمکی ---
def get_cpu_cores():
    """تعداد هسته‌های منطقی CPU را برمی‌گرداند"""
    try:
        count = psutil.cpu_count(logical=True)
        if count is None or count == 0:
            logging.warning("Could not detect CPU core count, defaulting to 1.")
            return 1
        return count
    except Exception as e:
        logging.error(f"Error getting CPU count: {e}")
        return 1 # fallback

def format_bytes_to_mb(byte_val):
    """بایت را به مگابایت تبدیل می‌کند"""
    return byte_val / (1024 * 1024)

def format_rate_mbps(bytes_per_second):
    """بایت بر ثانیه را به مگابایت بر ثانیه فرمت می کند (MB/s)"""
    mb_per_second = format_bytes_to_mb(bytes_per_second)
    if abs(mb_per_second) < 0.01:
        return "0.0 MB/s"
    else:
        return f"{mb_per_second:.1f} MB/s"

def is_script_really_admin():
    """Checks if the current script process is running with elevated privileges using Windows API (on Windows).
       Checks for UID == 0 on POSIX systems.
    """
    if os.name == 'nt':
        try:
            # Use ctypes to call Windows API function IsUserAnAdmin
            return ctypes.windll.shell32.IsUserAnAdmin() != 0
        except Exception:
            # Fallback check for Windows, might not be as reliable
            try:
                 # Attempt to list a directory typically restricted to admins (e.g., System32\config)
                 # This is not foolproof but can indicate elevation
                 os.listdir(os.path.join(os.environ.get('SystemRoot', 'C:\\Windows'), 'System32', 'config'))
                 return True
            except Exception:
                 return False
    else: # For Linux/macOS (POSIX systems)
        try:
             return os.geteuid() == 0
        except AttributeError:
             # geteuid might not exist on some systems, assume not root
             return False
        except Exception:
             return False


def run_as_admin():
    """Relaunches the current script with administrator privileges (Windows only)."""
    if os.name != 'nt':
        print("Error: Automatic elevation is only supported on Windows.")
        logging.error("Attempted automatic elevation on non-Windows OS.")
        return False

    try:
        script_path = os.path.abspath(sys.argv[0]) # Use sys.argv[0] for the path of the script/executable
        # Use ShellExecuteW to run the script again with the "runas" verb
        # Parameter 1: hWnd (handle to owner window, None here)
        # Parameter 2: lpVerb ("runas" to request elevation)
        # Parameter 3: lpFile (the program to run, which is the Python interpreter path)
        # Parameter 4: lpParameters (arguments for the program, which is the script path itself)
        # Parameter 5: lpDirectory (working directory, None means current directory)
        # Parameter 6: nShowCmd (how to show the window, 1 means normal window)
        success = ctypes.windll.shell32.ShellExecuteW(None, "runas", sys.executable, f'"{script_path}"', None, 1)

        # ShellExecute returns a value > 32 on success, otherwise an error code
        if success > 32:
            logging.info(f"Relaunching script '{script_path}' as administrator.")
            print("Requesting administrator privileges (UAC prompt should appear)...")
            return True # Relaunch initiated
        else:
            error_code = success # Error code if <= 32
            logging.error(f"Failed to relaunch script as administrator. ShellExecute error code: {error_code}")
            print(f"Error: Failed to request administrator privileges. ShellExecute error code: {error_code}")
            print("Please run the script/executable manually as administrator.")
            return False # Relaunch failed
    except Exception as e:
        logging.critical(f"Exception during administrator relaunch: {e}", exc_info=True)
        print(f"Critical error during administrator relaunch: {e}")
        print("Please run the script/executable manually as administrator.")
        return False


# --- تابع بازگشتی لاگ درخت فرآیندی ---
# این تابع از داده‌های جمع‌آوری و محاسبه شده در current_snapshot_data استفاده می‌کند
# و منابع را برای گره فعلی و زیردرختش جمع می‌کند
def log_process_tree(pid, children_map, cpu_cores, interval_duration, txt_handle, indent=""):
    """Logs information for a process and its subtree using pre-collected data
       and sums resources for the entire subtree rooted at pid.
    """
    global current_snapshot_data

    # If PID is not in current snapshot data (likely terminated), log its status and return zero sum
    if pid not in current_snapshot_data:
        try:
            name_field_length = max(1, 45 - len(indent)) # Adjust width based on indent
            txt_handle.write(f"{indent}{f'PID {pid}':<{name_field_length}}{str(pid):<8}{'Terminated/Missing':<15}{'-':<8}{'-':<12}{'-':<18}{'-':<10}\n")
        except Exception:
             txt_handle.write(f"{indent}Error logging terminated/missing process {pid}\n")
        # Return zero sum for terminated processes, count as an error for the tree total
        return {'cpu': 0.0, 'ws_kb': 0, 'delta_read_bytes': 0, 'delta_write_bytes': 0, 'error_count': 1}


    # Get pre-collected and calculated data for the current process
    process_data = current_snapshot_data[pid]
    process_name = process_data.get('name', 'N/A')
    process_status = process_data.get('status', 'N/A')
    # This CPU percentage is already scaled to ONE core and capped at 100%
    own_cpu_per_core = process_data.get('cpu_percent', 0.0)
    own_ws_kb = process_data.get('mem_ws_kb', 0)
    own_delta_read_bytes = process_data.get('delta_read_bytes', 0)
    own_delta_write_bytes = process_data.get('delta_write_bytes', 0)

    # --- Recursively call for children and sum their resources ---
    children_total = {'cpu': 0.0, 'ws_kb': 0, 'delta_read_bytes': 0, 'delta_write_bytes': 0, 'error_count': 0}
    # Get children PIDs that were found in the *current* snapshot and are mapped as children
    valid_children_pids = [p for p in children_map.get(pid, []) if p in current_snapshot_data]
    sorted_children_pids = sorted(valid_children_pids)


    for child_pid in sorted_children_pids:
        # Recursively log and sum for each valid child
        child_sum = log_process_tree(child_pid, children_map, cpu_cores, interval_duration, txt_handle, indent + INDENT_STRING)
        children_total['cpu'] += child_sum['cpu']
        children_total['ws_kb'] += child_sum['ws_kb']
        children_total['delta_read_bytes'] += child_sum['delta_read_bytes']
        children_total['delta_write_bytes'] += child_sum['delta_write_bytes']
        children_total['error_count'] += child_sum['error_count']

    # --- Calculate total resources for the current node (own resources + children's total) ---
    # Total CPU here is the sum of per-core percentages for itself and its children
    total_for_node = {
        'cpu': own_cpu_per_core + children_total['cpu'],
        'ws_kb': own_ws_kb + children_total['ws_kb'],
        'delta_read_bytes': own_delta_read_bytes + children_total['delta_read_bytes'],
        'delta_write_bytes': own_delta_write_bytes + children_total['delta_write_bytes'],
        # Count errors: 1 if this node had a fetch error + errors from children
        'error_count': (1 if process_status in ['access denied', 'error', 'fetch error', 'cpu error', 'mem error', 'io error'] else 0) + children_total['error_count']
    }


    # --- Format resource values for display ---
    display_name = process_name
    # Add count of valid children in parentheses if any
    if valid_children_pids:
         # Ensure the count is of children successfully processed, not just in children_map
         # The current logic counts valid children based on current_snapshot_data check above
         display_name += f" ({len(valid_children_pids)})"


    # CPU display (sum of per-core percentages)
    cpu_display = f"{total_for_node['cpu']:.1f}%"
    # Memory display (Working Set in MB, converted from KB)
    mem_display_mb = format_bytes_to_mb(total_for_node['ws_kb'] * 1024) # total_for_node['ws_kb'] is already in KB
    mem_display = f"{mem_display_mb:,.1f} MB" if mem_display_mb >= 0.1 else ("0.0 MB" if total_for_node['ws_kb'] == 0 else "< 0.1 MB")

    # Disk I/O Rate display (Read/Write MB/s over the interval)
    disk_read_rate_bps = 0.0
    disk_write_rate_bps = 0.0
    if interval_duration > 0.01:
         disk_read_rate_bps = total_for_node['delta_read_bytes'] / interval_duration
         disk_write_rate_bps = total_for_node['delta_write_bytes'] / interval_duration

    disk_read_display = format_rate_mbps(disk_read_rate_bps)
    disk_write_display = format_rate_mbps(disk_write_rate_bps)
    disk_display = "0.0 MB/s" if (disk_read_display == "0.0 MB/s" and disk_write_display == "0.0 MB/s") else f"{disk_read_display}/{disk_write_display}"

    network_display = "N/A" # Network per process is difficult with psutil cross-platform
    status_display = process_status

    # --- Write the formatted line to the text file ---
    # Calculate dynamic field length based on indent
    name_field_length = max(1, 45 - len(indent)) # Ensure minimum length is 1


    truncated_display_name = display_name
    # Truncate if needed, leaving space for "..." if field is long enough
    if len(truncated_display_name) > name_field_length and name_field_length > 3:
        truncated_display_name = truncated_display_name[:name_field_length-3] + "..."
    elif len(truncated_display_name) > name_field_length:
         truncated_display_name = truncated_display_name[:name_field_length] # Truncate hard if field is too short


    # Format the line with dynamic name field width and other fixed widths
    line = (f"{indent}{truncated_display_name:<{name_field_length}}"
            f"{str(pid):<8}"
            f"{status_display:<15}"
            f"{cpu_display:<8}" # Display the sum of per-core percentages
            f"{mem_display:<12}"
            f"{disk_display:<18}"
            f"{network_display:<10}")
    txt_handle.write(line + '\n')

    return total_for_node # Return the total resources for this subtree


# --- تابع اصلی مانیتورینگ ---
def monitor_like_task_manager(repeat_interval_seconds, target_app_name=None):
    """Main monitoring loop that collects data, builds tree, logs, and waits."""

    # File paths are already defined at the top using script_directory

    # system_summary_header is used only if ENABLE_SYSTEM_SUMMARY_CSV is True
    system_summary_header = ["Timestamp", "Total CPU Usage (%) (All Cores)", "Total RAM Usage (%)", "Total SWAP Usage (%)",
                             "Disk Read Count (Cumulative)", "Disk Write Count (Cumulative)",
                             "Disk Read MB (Cumulative)", "Disk Write MB (Cumulative)",
                             "Net Sent MB (Cumulative)", "Net Received MB (Cumulative)"]


    logging.info(f"Monitoring started. Interval: {repeat_interval_seconds}s")
    if target_app_name: logging.info(f"Filtering for process tree(s) containing: '{target_app_name}'")
    else: logging.info("Monitoring all processes.")
    logging.info(f"Snapshot output: {SNAPSHOT_FILENAME_TXT}")
    # Log the system summary file path only if enabled in settings
    if ENABLE_SYSTEM_SUMMARY_CSV:
        logging.info(f"Overall system summary: {SYSTEM_SUMMARY_FILENAME}")
    else:
        logging.info("System summary CSV output is disabled.")


    cpu_cores = get_cpu_cores()
    # Log the number of cores detected, which is used for scaling individual process CPU
    logging.info(f"Detected {cpu_cores} logical CPU cores. Process CPU will be shown as percentage of ONE core.")


    # Check if system summary file exists and has content *only if* writing is enabled
    system_summary_header_written = False
    if ENABLE_SYSTEM_SUMMARY_CSV:
        system_summary_header_written = os.path.exists(SYSTEM_SUMMARY_FILENAME) and os.path.getsize(SYSTEM_SUMMARY_FILENAME) > 0

    target_app_name_lower = target_app_name.lower() if target_app_name else None

    # last_snapshot_time needs to be initialized before the loop starts to calculate the first interval
    last_snapshot_time = time.time()

    global previous_io_counters, process_objects_cache, current_snapshot_data
    # These caches and previous_io_counters persist between loop iterations
    # They should be cleared only ONCE at the very start of the script execution (__main__ block)

    try:
        # Open the snapshot text file in append mode, ensuring UTF-8 encoding
        with open(SNAPSHOT_FILENAME_TXT, 'a', encoding='utf-8') as txt_snapshot_log:
            # Write header lines if the file is empty
            if os.path.getsize(SNAPSHOT_FILENAME_TXT) == 0:
                name_width_header = 45 # Fixed width for the Name column header
                header_line = (f"{'Name':<{name_width_header}}"
                               f"{'PID':<8}{'Status':<15}{'CPU%':<8}" # CPU% is per ONE core
                               f"{'Memory':<12}{'Disk (R/W MB/s)':<18}{'Network':<10}\n")
                txt_snapshot_log.write(header_line)
                txt_snapshot_log.write("-" * (name_width_header + 8 + 15 + 8 + 12 + 18 + 10) + "\n")


            # --- Main monitoring loop ---
            while True:
                snapshot_start_time = time.time()
                # Calculate the actual duration since the end of the last snapshot processing
                # This is used for calculating rates (Disk I/O) over the interval
                actual_interval_duration = snapshot_start_time - last_snapshot_time

                # If the interval was too short, wait a bit to get more meaningful deltas
                if actual_interval_duration < 0.5:
                     sleep_short = 0.5 - actual_interval_duration
                     if sleep_short > 0:
                          time.sleep(sleep_short)
                          snapshot_start_time = time.time() # Recalculate start time and duration after waiting
                          actual_interval_duration = snapshot_start_time - last_snapshot_time

                last_snapshot_time = snapshot_start_time # Update the time for the next iteration's interval calculation

                now = datetime.datetime.now()
                timestamp_str = now.strftime("%Y-%m-%d %H:%M:%S")
                logging.info(f"--- Snapshot @ {timestamp_str} (Interval: {actual_interval_duration:.2f}s) ---")

                # --- 1. Collect raw data for all processes and calculate metrics (CPU%, Memory, IO Delta) ---
                # Clear data from the previous snapshot before populating for the current one
                current_snapshot_data.clear()
                current_io_snapshot = {} # Temporary dict to store I/O counters for THIS snapshot
                pids_found_this_iter = set() # Keep track of PIDs seen in this iteration
                newly_cached_pids = [] # PIDs added/re-cached in this iteration for priming


                logging.debug("Collecting process data and calculating metrics...")
                try:
                    # Fetch basic info for all processes first
                    all_processes_this_iter = list(psutil.process_iter(['pid', 'ppid', 'name', 'status'], ad_value=None))

                    # Iterate through processes to collect detailed data and calculate metrics
                    for proc in all_processes_this_iter:
                        # Skip if essential info is missing
                        if proc.info is None or proc.info.get('pid') is None: continue

                        pid = proc.info['pid']
                        pids_found_this_iter.add(pid)

                        # Try to get the process object, reuse from cache if possible
                        process = None
                        try:
                            # Reuse from cache if running, otherwise get new object for this PID
                            if pid in process_objects_cache and process_objects_cache[pid].is_running():
                                process = process_objects_cache[pid]
                            else:
                                process = psutil.Process(pid) # Get a new process object
                                process_objects_cache[pid] = process # Cache the new object
                                newly_cached_pids.append(pid) # Add to list for priming
                                # logging.debug(f"Cached/Re-cached PID {pid}") # Log moved to priming block

                        except (psutil.NoSuchProcess, psutil.AccessDenied):
                            # Handle processes that terminated or became inaccessible during the iteration
                            if pid in process_objects_cache: del process_objects_cache[pid] # Remove from object cache
                            # No need to remove from previous_io_counters here as it's fully replaced later
                            # logging.debug(f"Process {pid} ended/inaccessible during iteration.") # Log moved outside loop
                            # Add a minimal entry to current_snapshot_data to mark its status
                            current_snapshot_data[pid] = {'pid': pid, 'ppid': proc.info.get('ppid'),
                                                           'name': proc.info.get('name', 'N/A'),
                                                           'status': proc.info.get('status', 'terminated'), # Explicitly set status to terminated
                                                           'cpu_percent': 0.0, 'mem_ws_kb': 0,
                                                           'delta_read_bytes': 0, 'delta_write_bytes': 0}
                            continue # Skip fetching other details if process object is not available


                        # --- Fetch specific resources for the process object ---
                        ppid = proc.info.get('ppid', None)
                        name = proc.info.get('name', 'N/A') or 'N/A' # Use name from proc.info as primary
                        status = proc.info.get('status', 'N/A') # Use status from proc.info as primary

                        # CPU usage percentage (relative to ONE logical core, capped at 100%)
                        cpu_val_per_core = 0.0
                        try:
                            # Get CPU usage since the last call to process.cpu_percent(None) for this object.
                            # This value is relative to the total capacity across ALL logical cores.
                            raw_cpu_total_cores = process.cpu_percent(interval=None)
                            # Scale it to be a percentage of a SINGLE logical core
                            scaled_cpu = raw_cpu_total_cores / cpu_cores if cpu_cores > 0 else raw_cpu_total_cores
                            # Cap the percentage at 100% per process, mimicking Task Manager's process list view
                            cpu_val_per_core = min(100.0, scaled_cpu)

                        except (psutil.NoSuchProcess, psutil.AccessDenied, Exception) as e:
                             # Update status if a resource-specific error occurs, unless it's already terminated/access denied
                             if status not in ['terminated', 'access denied']: status = f'cpu error'
                             logging.debug(f"Error fetching CPU for P{pid}: {e}", exc_info=False)


                        # Memory usage (Resident Set Size in KB)
                        mem_ws_kb = 0
                        try:
                            mem_info = process.memory_info()
                            mem_ws_kb = mem_info.rss // 1024 # Resident Set Size is often used as a proxy for Working Set
                        except (psutil.NoSuchProcess, psutil.AccessDenied, Exception) as e:
                            if status not in ['terminated', 'access denied', 'cpu error']: status = f'mem error'
                            logging.debug(f"Error fetching Mem for P{pid}: {e}", exc_info=False)

                        # Disk I/O Delta (bytes read/written during the *last* interval)
                        current_io = None
                        read_delta = 0
                        write_delta = 0
                        try:
                            current_io = process.io_counters()
                            # Store the current I/O counters object for this PID, to be used in the *next* iteration's delta calculation
                            current_io_snapshot[pid] = current_io

                            # Calculate the delta by comparing current counters to counters from the *previous* snapshot
                            if pid in previous_io_counters:
                                prev_io = previous_io_counters[pid]
                                # Calculate difference, ensure it's not negative (can happen on some platforms/cases)
                                read_delta = max(0, current_io.read_bytes - prev_io.read_bytes)
                                write_delta = max(0, current_io.write_bytes - prev_io.write_bytes)
                            else:
                                # If this is the first time we see this PID in previous_io_counters,
                                # the delta over the "interval" is considered 0 for rate calculation.
                                read_delta = 0
                                write_delta = 0

                        except (psutil.NoSuchProcess, psutil.AccessDenied, NotImplementedError, OSError) as e:
                            # Handle I/O specific errors
                            if status not in ['terminated', 'access denied', 'cpu error', 'mem error']: status = f'io error'
                            logging.debug(f"Error fetching IO for P{pid}: {e}", exc_info=False)
                        except Exception as e:
                            # Handle any other unexpected errors during resource fetching
                            if status not in ['terminated', 'access denied', 'cpu error', 'mem error', 'io error']: status = f'fetch error'
                            logging.warning(f"Unexpected Err fetching resources P{pid}: {e}", exc_info=False)


                        # Store all collected and calculated data for this PID in the current snapshot's data dict
                        current_snapshot_data[pid] = {
                            'pid': pid,
                            'ppid': ppid,
                            'name': name,
                            'status': status,
                            'cpu_percent': cpu_val_per_core, # Store the per-core capped value
                            'mem_ws_kb': mem_ws_kb,
                            'delta_read_bytes': read_delta,
                            'delta_write_bytes': write_delta,
                        }

                    # --- Priming CPU and IO for newly cached/re-cached processes ---
                    # After collecting data for all processes, iterate through those whose objects
                    # were newly obtained or re-obtained in this iteration. Call cpu_percent(None)
                    # and io_counters() once to reset their internal counters. This ensures the
                    # *next* call in the subsequent loop iteration measures usage over the interval.
                    if newly_cached_pids:
                        logging.debug(f"Priming {len(newly_cached_pids)} new/re-cached PIDs...")
                    for pid_to_prime in newly_cached_pids:
                         # Ensure the process object is still in the cache before priming
                         if pid_to_prime in process_objects_cache:
                             try:
                                 # Calling cpu_percent(None) once resets its internal timer
                                 process_objects_cache[pid_to_prime].cpu_percent(interval=None)
                                 # Calling io_counters() once and storing it ensures delta calculation
                                 # is correct from the next interval onwards.
                                 primed_io = process_objects_cache[pid_to_prime].io_counters()
                                 previous_io_counters[pid_to_prime] = primed_io # Store this as the "previous" for the *next* iter
                                 current_io_snapshot[pid_to_prime] = primed_io # Also ensure it's in current_io_snapshot if it wasn't fetched above

                             except Exception:
                                 pass # Ignore errors during priming

                    # Log the total number of processes for which data was collected in this snapshot
                    logging.debug(f"Collected data for {len(current_snapshot_data)} processes.")

                except Exception as e:
                    # Handle critical errors during the data collection phase itself
                    logging.critical(f"Critical error during process data collection: {e}", exc_info=True)
                    print(f"Error collecting process data. Check '{LOG_FILENAME}'.")
                    # Sleep for the requested interval before the next attempt
                    time.sleep(repeat_interval_seconds)
                    continue # Skip the rest of the loop for this snapshot if data collection failed


                # --- 2. Update global caches and clean up terminated processes ---
                # Update previous_io_counters for the NEXT iteration by storing the counters from THIS snapshot
                # This replaces the previous state entirely based on successful queries in this iteration.
                # Processes not in current_io_snapshot will implicitly be missing from previous_io_counters for the next iter.
                previous_io_counters = current_io_snapshot


                # Clean up process object cache: remove objects for PIDs that were not found in this iteration
                pids_to_remove_from_cache = set(process_objects_cache.keys()) - pids_found_this_iter
                for pid in pids_to_remove_from_cache:
                    if pid in process_objects_cache:
                         del process_objects_cache[pid]
                    # Note: No need to explicitly remove from previous_io_counters here
                    # because it's completely overwritten by current_io_snapshot above.

                if pids_to_remove_from_cache:
                     logging.debug(f"Removed {len(pids_to_remove_from_cache)} ended PIDs from process object cache.")


                # --- 3. Build process tree structure and identify roots ---
                # The process_map_for_tree will be used by the recursive logging function.
                # It uses the data already processed and stored in current_snapshot_data.
                process_map_for_tree = current_snapshot_data

                # children_map maps parent PIDs to lists of child PIDs found in the current snapshot
                children_map = defaultdict(list)
                all_pids_in_snapshot = set(current_snapshot_data.keys())
                target_pids_found = set() # PIDs matching the target application name
                root_candidates = set() # PIDs that appear to be roots (ppid 0, None, or parent not in snapshot)

                # Iterate through the collected data to build the children map and find roots/targets
                for pid, data in current_snapshot_data.items():
                     ppid = data.get('ppid')
                     # Add to children_map only if the parent is also in the current snapshot data
                     if ppid is not None and ppid != 0 and ppid in all_pids_in_snapshot:
                          children_map[ppid].append(pid)

                     # A process is a root candidate if its parent is PID 0 (system), None,
                     # or if its parent PID exists but was not found in this snapshot.
                     if ppid is None or ppid == 0 or ppid not in all_pids_in_snapshot:
                         root_candidates.add(pid)

                     # Identify processes matching the target application name (case-insensitive)
                     if target_app_name_lower and data.get('name', '').lower() == target_app_name_lower:
                         target_pids_found.add(pid)


                # Determine which root PIDs to log based on filtering settings
                root_pids_to_log = []
                if target_app_name:
                     # If filtering, find the roots of the trees containing the target app processes
                     if not target_pids_found:
                         logging.info(f"Target '{target_app_name}' not found in this snapshot.")
                         root_pids_to_log = [] # No roots to log if target not found
                     else:
                         # Trace up from the target processes to find their highest ancestor roots within the snapshot
                         roots_of_target_trees = set()
                         search_queue = list(target_pids_found); # Start search from target PIDs
                         visited = set(target_pids_found) # Keep track of visited PIDs to avoid infinite loops

                         while search_queue:
                              current_pid = search_queue.pop(0)
                              data = current_snapshot_data.get(current_pid)
                              if not data: continue # Should not happen if starting from target_pids_found

                              ppid = data.get('ppid')

                              if ppid is None or ppid == 0 or ppid not in all_pids_in_snapshot:
                                   # Found a root or a process whose parent is not in the current snapshot -> add to roots
                                   roots_of_target_trees.add(current_pid)
                              elif ppid not in visited:
                                   # Move up to the parent if not already visited
                                   visited.add(ppid)
                                   search_queue.append(ppid)

                         # Sort the root PIDs for consistent output order
                         root_pids_to_log = sorted(list(roots_of_target_trees))
                         logging.info(f"Identified {len(root_pids_to_log)} root(s) for '{target_app_name}'.")

                else: # No target app specified, log all identified root trees
                     root_pids_to_log = sorted(list(root_candidates))
                     logging.debug(f"Identified {len(root_pids_to_log)} main trees to log.")


                # --- 4. Write process tree(s) to the snapshot text file ---
                txt_snapshot_log.write(f"\n--- Snapshot @ {timestamp_str} ---\n")
                if not root_pids_to_log:
                    # Message if no processes were found matching the criteria
                    txt_snapshot_log.write(f"No processes found matching criteria"
                                           f"{f' for {target_app_name}' if target_app_name else ''}.\n")
                else:
                    total_errors_in_log = 0 # Counter for errors encountered during tree logging
                    # Iterate through the determined root PIDs and log their trees recursively
                    for root_pid in root_pids_to_log:
                         # Ensure the root PID is still present in the snapshot data before attempting to log its tree
                         if root_pid in process_map_for_tree:
                             # Call the recursive logging function. It uses current_snapshot_data internally.
                             subtree_info = log_process_tree(root_pid, children_map, cpu_cores, actual_interval_duration, txt_snapshot_log)
                             total_errors_in_log += subtree_info.get('error_count', 0)
                         else:
                              # Handle cases where a root process disappeared between building the list and logging
                              logging.warning(f"Root PID {root_pid} disappeared just before logging process tree.")
                              # Log a line indicating the disappeared root
                              try:
                                   name_field_length = max(1, 45) # Fixed width for root lines
                                   txt_snapshot_log.write(f"{f'PID {root_pid}':<{name_field_length}}{str(root_pid):<8}{'Disappeared':<15}{'-':<8}{'-':<12}{'-':<18}{'-':<10}\n")
                              except Exception:
                                   txt_snapshot_log.write(f"Error logging disappeared root process {root_pid}\n")


                    # Log the total number of errors encountered during this snapshot's tree logging
                    logging.info(f"Snapshot logged. Errors encountered: {total_errors_in_log}")
                    # Ensure data is written to the file immediately
                    txt_snapshot_log.flush()


                # --- 5. Log system-wide summary to CSV file (Conditional based on settings) ---
                if ENABLE_SYSTEM_SUMMARY_CSV: # <<< This block is executed only if the setting is True
                    try:
                        # Get system-wide metrics (CPU is total usage across all cores here, usually matching Performance tab)
                        total_cpu_overall = psutil.cpu_percent(interval=None) # System-wide CPU since last call
                        total_mem = psutil.virtual_memory() # System-wide RAM usage
                        total_swap = psutil.swap_memory() # System-wide Swap usage
                        disk_io_sys = psutil.disk_io_counters() # Cumulative system-wide disk I/O counters
                        net_io_sys = psutil.net_io_counters() # Cumulative system-wide network I/O counters

                        # Prepare data row as a dictionary matching the header
                        system_summary_data = {
                            "Timestamp": timestamp_str,
                            "Total CPU Usage (%) (All Cores)": f"{total_cpu_overall:.2f}",
                            "Total RAM Usage (%)": f"{total_mem.percent:.2f}",
                            "Total SWAP Usage (%)": f"{total_swap.percent:.2f}",
                            "Disk Read Count (Cumulative)": disk_io_sys.read_count if disk_io_sys else 0,
                            "Disk Write Count (Cumulative)": disk_io_sys.write_count if disk_io_sys else 0,
                            "Disk Read MB (Cumulative)": f"{format_bytes_to_mb(disk_io_sys.read_bytes):.2f}" if disk_io_sys else "0.00",
                            "Disk Write MB (Cumulative)": f"{format_bytes_to_mb(disk_io_sys.write_bytes):.2f}" if disk_io_sys else "0.00",
                            "Net Sent MB (Cumulative)": f"{format_bytes_to_mb(net_io_sys.bytes_sent):.2f}" if net_io_sys else "0.00",
                            "Net Received MB (Cumulative)": f"{format_bytes_to_mb(net_io_sys.bytes_recv):.2f}" if net_io_sys else "0.00"
                        }

                        # Open the system summary CSV file in append mode, ensure newline='' for correct CSV writing
                        with open(SYSTEM_SUMMARY_FILENAME, 'a', newline='', encoding='utf-8') as sys_summary_csv:
                            writer = csv.DictWriter(sys_summary_csv, fieldnames=system_summary_header)
                            # Write the header row only if the file is empty
                            if not system_summary_header_written:
                                # Check if the file is empty by seeking to the end and checking the position
                                sys_summary_csv.seek(0, os.SEEK_END);
                                if sys_summary_csv.tell() == 0:
                                    writer.writeheader()
                                system_summary_header_written = True # Mark header as written for subsequent iterations

                            # Write the data row for the current snapshot
                            writer.writerow(system_summary_data)
                        logging.debug(f"Sys summary: CPU={total_cpu_overall:.2f}%, RAM={total_mem.percent:.2f}%, SWAP={total_swap.percent:.2f}%")
                    except Exception as e:
                        logging.error(f"Error writing system summary log: {e}", exc_info=True)
                # <<< End of conditional block for SYSTEM_SUMMARY_CSV


                # --- 6. Sleep until the next interval is due ---
                snapshot_end_time = time.time()
                elapsed_time = snapshot_end_time - snapshot_start_time # Time taken for this snapshot processing
                # Calculate remaining time to sleep to meet the repeat_interval_seconds
                # Ensure minimum sleep time even if processing took longer than the interval (min 0.5s)
                sleep_time = max(0.5, repeat_interval_seconds - elapsed_time)
                logging.info(f"Snapshot processing took {elapsed_time:.2f}s. Sleeping for {sleep_time:.2f}s...")
                time.sleep(sleep_time) # Pause execution


    except KeyboardInterrupt:
        # Handle user interruption (Ctrl+C)
        logging.info("Monitoring stopped by user.")
        print("\nMonitoring stopped.")
    except Exception as e:
        # Handle any other unexpected critical errors in the main loop
        logging.critical(f"Critical error in main loop: {e}", exc_info=True)
        print(f"Error: Critical error occurred. Check '{LOG_FILENAME}' for details.")
        # Note: We don't exit immediately here to allow the logger to finish writing


# --- Script Execution Entry Point ---
# This block runs when the script is executed directly
if __name__ == "__main__":
    print("--- Task Manager Style Monitor ---")
    # Check if required libraries are installed
    try:
        import psutil
        print("- psutil library found.")
    except ImportError:
        print("Error: psutil library not found. Please install it: pip install psutil")
        sys.exit(1) # Exit if psutil is not found

    # Check for pywin32 on Windows, it's recommended but not strictly essential for basic function
    if os.name == 'nt':
        try:
            import win32api
            print("- pywin32 library found (recommended for full features on Windows).")
        except ImportError:
            # Warning if pywin32 is missing on Windows, as auto-elevation relies on ctypes which is part of stdlib
            # but win32api is generally useful for Windows interactions
            print("Warning: pywin32 library not found. Some features might be limited. Install: pip install pywin32")


    # --- Check for Administrator/root privileges and auto-elevate on Windows ---
    if os.name == 'nt': # Only perform elevation check/attempt on Windows
        if is_script_really_admin():
             # If already running as admin, print success status
             print("Status: Script is running with Administrator privileges.")
        else:
             # If not running as admin, print warning and attempt elevation
             print("Status: Script DETECTED as *NOT* running with Administrator privileges.")
             logging.warning("Script is not running with administrator privileges. Attempting to elevate.")
             # Attempt to run as admin. If successful, the current process will exit.
             if run_as_admin():
                 # If run_as_admin returned True, it means the relaunch was attempted.
                 # This current non-admin process should now exit.
                 sys.exit(0)
             else:
                 # If run_as_admin returned False, elevation failed.
                 # Continue running in the original non-admin process but inform the user.
                 print("Continuing execution without administrator privileges. Data may be incomplete (e.g., process tree, IO).")
                 print("NOTE: To get complete data, please run the script/executable manually as administrator.")
    # For non-Windows OS, check for root but don't auto-elevate
    elif os.name != 'nt':
        print("Status: Running on non-Windows OS.")
        if is_script_really_admin():
             print("Status: Script detected as running with root privileges.")
        else:
             # Warn if not running as root on non-Windows
             print("Status: Script detected as *NOT* running with root privileges. Data may be incomplete.")
             print("NOTE: Run with root privileges (e.g., using sudo python your_script.py) for complete data access.")


    # --- Get user input for monitoring interval and target application name ---
    repeat_seconds = 10 # Default interval in seconds
    while True:
        try:
            # Prompt user for interval, use default if empty input
            repeat_seconds_str = input(f"Enter monitoring interval seconds [{repeat_seconds}]: ") or str(repeat_seconds)
            repeat_seconds = int(repeat_seconds_str) # Convert input to integer
            if repeat_seconds <= 0:
                 # Interval must be positive
                 raise ValueError("Interval must be positive.")
            if repeat_seconds < 2:
                 # Warning for very short intervals
                 logging.warning("Interval less than 2 seconds might increase overhead and affect accuracy.")
            break # Exit loop if input is valid
        except ValueError as e:
            # Handle invalid input (not an integer, or <= 0)
            print(f"Invalid input: {e}. Please enter a positive integer.")

    # Prompt user for target process name (optional)
    target_name_input = input("Enter exact process name to filter (e.g., chrome.exe) [Blank for all]: ").strip()

    print("\nStarting monitoring loop...")
    print(f"Output Files (will be created/appended in the script/executable directory):")
    print(f" - Snapshot: {SNAPSHOT_FILENAME_TXT}")
    # Print system summary file path only if enabled
    if ENABLE_SYSTEM_SUMMARY_CSV:
        print(f" - System Summary: {SYSTEM_SUMMARY_FILENAME}")
    print(f" - Script Log: {LOG_FILENAME}")
    print("(CPU%: Percentage of ONE logical core. Disk: Read/Write MB/s rate for the interval. Network: N/A per process)")
    print("Press Ctrl+C to stop.")

    # --- Initialize/Clear global states for the start of the monitoring ---
    # These need to be empty for the first snapshot to work correctly
    previous_io_counters.clear()
    process_objects_cache.clear()
    current_snapshot_data.clear()

    # --- Start the main monitoring function ---
    monitor_like_task_manager(repeat_seconds, target_app_name=target_name_input or None)