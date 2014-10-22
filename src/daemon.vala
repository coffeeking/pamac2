/*
 *  pamac-vala
 *
 *  Copyright (C) 2014  Guillaume Benoit <guillaume@manjaro.org>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a get of the GNU General Public License
 *  along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

using Alpm;
using Pamac;
using Polkit;

// i18n
const string GETTEXT_PACKAGE = "pacman";

PamacServer server;
MainLoop loop;

[DBus (name = "org.manjaro.pamac")]
public class PamacServer : Object {
	Alpm.Config alpm_config;
	Pamac.Config pamac_config;
	unowned Alpm.DB localdb;
	unowned Alpm.List<DB?> syncdbs;
	public uint64 previous_percent;
	unowned Alpm.List<string?> local_packages;
	int force_refresh;
	bool emit_refreshed_signal;
	public Cond provider_cond;
	public Mutex provider_mutex;
	public int? choosen_provider;

	public signal void emit_event (uint event, string msg);
	public signal void emit_providers (string depend, string[] providers);
	public signal void emit_progress (uint progress, string action, string pkgname, int percent, uint n_targets, uint current_target);
	public signal void emit_download (string filename, uint64 xfered, uint64 total);
	public signal void emit_totaldownload (uint64 total);
	public signal void emit_log (uint level, string msg);
	public signal void emit_updates (Updates updates);
	public signal void emit_refreshed (ErrorInfos error);
	public signal void emit_trans_prepared (ErrorInfos error);
	public signal void emit_trans_committed (ErrorInfos error);

	public PamacServer () {
		previous_percent = 0;
		local_packages = null;
		get_handle ();
		force_refresh = 0;
		emit_refreshed_signal = true;
	}

	private void get_handle () {
		alpm_config = new Alpm.Config ("/etc/pacman.conf");
		pamac_config = new Pamac.Config ("/etc/pamac.conf");
		alpm_config.handle.eventcb = (EventCallBack) cb_event;
		alpm_config.handle.progresscb = (ProgressCallBack) cb_progress;
		alpm_config.handle.questioncb = (QuestionCallBack) cb_question;
		alpm_config.handle.dlcb = (DownloadCallBack) cb_download;
		alpm_config.handle.totaldlcb = (TotalDownloadCallBack) cb_totaldownload;
		alpm_config.handle.logcb = (LogCallBack) cb_log;
		localdb = alpm_config.handle.localdb;
		syncdbs = alpm_config.handle.syncdbs;
	}

	public void write_config (HashTable<string,string> new_conf, GLib.BusName sender) {
		try {
			Polkit.Authority authority = Polkit.Authority.get_sync (null);
			Polkit.Subject subject = Polkit.SystemBusName.new (sender);
			Polkit.AuthorizationResult result = authority.check_authorization_sync
							(subject,
							"org.manjaro.pamac.commit",
							null,
							Polkit.CheckAuthorizationFlags.ALLOW_USER_INTERACTION,
							null);
			if (result.get_is_authorized ()) {
				pamac_config.write (new_conf);
			}
		} catch (GLib.Error e) {
			stderr.printf ("%s\n", e.message);
		}
	}

	private void refresh_real () {
		ErrorInfos err = ErrorInfos ();
		string[] details = {};
		uint success = 0;
		int ret = alpm_config.handle.trans_init (0);
		if (ret == 0) {
			foreach (unowned DB db in syncdbs) {
				ret = db.update (force_refresh);
				if (ret >= 0) {
					success++;
				}
			}
			// We should always succeed if at least one DB was upgraded - we may possibly
			// fail later with unresolved deps, but that should be rare, and would be expected
			if (success == 0) {
				err.str = _("failed to synchronize any databases\n");
				details += Alpm.strerror (alpm_config.handle.errno ()) + "\n";
				err.details = details;
			}
			trans_release ();
			get_handle ();
			if (emit_refreshed_signal)
				emit_refreshed (err);
			else
				emit_refreshed_signal = true;
		}
	}

	public async void refresh (int force, bool emit_signal) {
		force_refresh = force;
		emit_refreshed_signal = emit_signal;
		try {
			new Thread<void*>.try ("refresh thread", (ThreadFunc) refresh_real);
		} catch (GLib.Error e) {
			stderr.printf ("%s\n", e.message);
		}
	}

	public UpdatesInfos[] get_updates () {
		UpdatesInfos[] updates = {};
		updates = get_syncfirst_updates (alpm_config);
		if (updates.length != 0) {
			return updates;
		} else {
			string[] ignore_pkgs = get_ignore_pkgs (alpm_config);
			updates = get_repos_updates (alpm_config, ignore_pkgs);
			if (pamac_config.enable_aur) {
				UpdatesInfos[] aur_updates = get_aur_updates (alpm_config, ignore_pkgs);
				foreach (UpdatesInfos infos in aur_updates)
					updates += infos;
			}
			return updates;
		}
	}

	public ErrorInfos trans_init (TransFlag transflags) {
		ErrorInfos err = ErrorInfos ();
		int ret = alpm_config.handle.trans_init (transflags);
		if (ret == -1) {
			//err = _("failed to init transaction (%s)\n").printf (Alpm.strerror (errno));
			err.str = Alpm.strerror (alpm_config.handle.errno ()) + "\n";
		}
		return err;
	}

	public ErrorInfos trans_sysupgrade (int enable_downgrade) {
		ErrorInfos err = ErrorInfos ();
		int ret = alpm_config.handle.trans_sysupgrade (enable_downgrade);
		if (ret == -1) {;
			err.str = Alpm.strerror (alpm_config.handle.errno ()) + "\n";
		}
		return err;
	}

	public ErrorInfos trans_add_pkg (string pkgname) {
		ErrorInfos err = ErrorInfos ();
		unowned Package? pkg = null;
		//pkg =  alpm_config.handle.find_dbs_satisfier (syncdbs, pkgname);  
		foreach (var db in syncdbs) {
			pkg = find_satisfier (db.pkgcache, pkgname);
			if (pkg != null)
				break;
		}
		if (pkg == null)  {
			err.str = _("target not found: %s\n").printf (pkgname);
			return err;
		}
		int ret = alpm_config.handle.trans_add_pkg (pkg);
		if (ret == -1) {
			Alpm.Errno errno = alpm_config.handle.errno ();
			if (errno == Errno.TRANS_DUP_TARGET || errno == Errno.PKG_IGNORED)
				// just skip duplicate or ignored targets
				return err;
			else {
				err.str = "'%s': %s\n".printf (pkg.name, Alpm.strerror (errno));
				return err;
			}
		}
		return err;
	}

	public ErrorInfos trans_load_pkg (string pkgpath) {
		ErrorInfos err = ErrorInfos ();
		unowned Package? pkg = alpm_config.handle.load_file (pkgpath, 1, alpm_config.handle.localfilesiglevel);
		if (pkg == null) {
			err.str = "'%s': %s\n".printf (pkgpath, Alpm.strerror (alpm_config.handle.errno ()));
			return err;
		} else {
			int ret = alpm_config.handle.trans_add_pkg (pkg);
			if (ret == -1) {
				Alpm.Errno errno = alpm_config.handle.errno ();
				if (errno == Errno.TRANS_DUP_TARGET || errno == Errno.PKG_IGNORED) {
					// just skip duplicate or ignored targets
					return err;
				} else {
					err.str = "'%s': %s\n".printf (pkg.name, Alpm.strerror (errno));
					return err;
				}
			}
		}
		return err;
	}

	public ErrorInfos trans_remove_pkg (string pkgname) {
		ErrorInfos err = ErrorInfos ();
		unowned Package? pkg = localdb.get_pkg (pkgname);
		if (pkg == null) {
			err.str = _("target not found: %s\n").printf (pkgname);
			return err;
		}
		int ret = alpm_config.handle.trans_remove_pkg (pkg);
		if (ret == -1) {
			err.str = "'%s': %s\n".printf (pkg.name, Alpm.strerror (alpm_config.handle.errno ()));
		}
		return err;
	}

	public void trans_prepare_real () {
		ErrorInfos err = ErrorInfos ();
		string[] details = {};
		Alpm.List<void*> err_data = null;
		int ret = alpm_config.handle.trans_prepare (out err_data);
		if (ret == -1) {
			Alpm.Errno errno = alpm_config.handle.errno ();
			//err = _("failed to prepare transaction (%s)\n").printf ();
			err.str = Alpm.strerror (errno) + "\n";
			switch (errno) {
				case Errno.PKG_INVALID_ARCH:
					foreach (void *i in err_data) {
						char *pkgname = i;
						details += _("package %s does not have a valid architecture\n").printf (pkgname);
					}
					break;
				case Errno.UNSATISFIED_DEPS:
					foreach (void *i in err_data) {
						DepMissing *miss = i;
						string depstring = miss->depend.compute_string ();
						details += _("%s: requires %s\n").printf (miss->target, depstring);
					}
					break;
				case Errno.CONFLICTING_DEPS:
					foreach (void *i in err_data) {
						Conflict *conflict = i;
						// only print reason if it contains new information
						if (conflict->reason.mod == DepMod.ANY)
							details += _("%s and %s are in conflict\n").printf (conflict->package1, conflict->package2);
						else {
							string reason = conflict->reason.compute_string ();
							details += _("%s and %s are in conflict (%s)\n").printf (conflict->package1, conflict->package2, reason);
						}
					}
					break;
				default:
					break;
			}
			err.details = details;
			trans_release ();
		}
		emit_trans_prepared (err);
	}

	public async void trans_prepare () {
		try {
			new Thread<void*>.try ("prepare thread", (ThreadFunc) trans_prepare_real);
		} catch (GLib.Error e) {
			stderr.printf ("%s\n", e.message);
		}
	}

	public void choose_provider (int provider) {
		provider_mutex.lock ();
		choosen_provider = provider;
		provider_cond.signal ();
		provider_mutex.unlock ();
	}

	public UpdatesInfos[] trans_to_add () {
		UpdatesInfos info = UpdatesInfos ();
		UpdatesInfos[] infos = {};
		foreach (unowned Package pkg in alpm_config.handle.trans_to_add ()) {
			info.name = pkg.name;
			info.version = pkg.version;
			// if pkg was load from a file, pkg.db is null
			if (pkg.db != null)
				info.db_name = pkg.db.name;
			else
				info.db_name = "";
			info.tarpath = "";
			info.download_size = pkg.download_size;
			infos += info;
		}
		return infos;
	}

	public UpdatesInfos[] trans_to_remove () {
		UpdatesInfos info = UpdatesInfos ();
		UpdatesInfos[] infos = {};
		foreach (unowned Package pkg in alpm_config.handle.trans_to_remove ()) {
			info.name = pkg.name;
			info.version = pkg.version;
			info.db_name = pkg.db.name;
			info.tarpath = "";
			info.download_size = pkg.download_size;
			infos += info;
		}
		return infos;
	}

	private void trans_commit_real () {
		ErrorInfos err = ErrorInfos ();
		string[] details = {};
		Alpm.List<void*> err_data = null;
		int ret = alpm_config.handle.trans_commit (out err_data);
		if (ret == -1) {
			Alpm.Errno errno = alpm_config.handle.errno ();
			//err = _("failed to commit transaction (%s)\n").printf (Alpm.strerror (errno));
			err.str = Alpm.strerror (errno) + "\n";
			switch (errno) {
				case Alpm.Errno.FILE_CONFLICTS:
					TransFlag flags = alpm_config.handle.trans_get_flags ();
					if ((flags & TransFlag.FORCE) != 0) {
						details += _("unable to %s directory-file conflicts\n").printf ("--force");
					}
					foreach (void *i in err_data) {
						FileConflict *conflict = i;
						switch (conflict->type) {
							case FileConflictType.TARGET:
								details += _("%s exists in both '%s' and '%s'\n").printf (conflict->file, conflict->target, conflict->ctarget);
								break;
							case FileConflictType.FILESYSTEM:
								details += _("%s: %s exists in filesystem\n").printf (conflict->target, conflict->file);
								break;
						}
					}
					break;
				case Alpm.Errno.PKG_INVALID:
				case Alpm.Errno.PKG_INVALID_CHECKSUM:
				case Alpm.Errno.PKG_INVALID_SIG:
				case Alpm.Errno.DLT_INVALID:
					foreach (void *i in err_data) {
						char *filename = i;
						details += _("%s is invalid or corrupted\n").printf (filename);
					}
					break;
				default:
					break;
			}
			err.details = details;
		}
		trans_release ();
		get_handle ();
		emit_trans_committed (err);
	}

	public async void trans_commit (GLib.BusName sender) {
		try {
			Polkit.Authority authority = Polkit.Authority.get_sync (null);
			Polkit.Subject subject = Polkit.SystemBusName.new (sender);
			Polkit.AuthorizationResult result = authority.check_authorization_sync
							(subject,
							"org.manjaro.pamac.commit",
							null,
							Polkit.CheckAuthorizationFlags.ALLOW_USER_INTERACTION,
							null);
			if (result.get_is_authorized ()) {
				new Thread<void*>.try ("commit thread", (ThreadFunc) trans_commit_real);
			} else {
				ErrorInfos err = ErrorInfos ();
				err.str = "Not Authorized\n";
				emit_trans_committed (err);
				trans_release ();
			}
		} catch (GLib.Error e) {
			stderr.printf ("%s\n", e.message);
		}
	}

	public int trans_release () {
		return alpm_config.handle.trans_release ();
	}

	public void trans_cancel () {
		alpm_config.handle.trans_interrupt ();
		alpm_config.handle.trans_release ();
		get_handle ();
	}

	public void quit () {
		GLib.File lockfile = GLib.File.new_for_path ("/var/lib/pacman/db.lck");
		if (lockfile.query_exists () == false)
			loop.quit ();
	}
// End of Server Object
}

private void write_log_file (string event) {
	var now = new DateTime.now_local ();
	string log = "%s %s".printf (now.format ("[%Y-%m-%d %H:%M]"), event);
	var file = GLib.File.new_for_path ("/var/log/pamac.log");
	try {
		// creating a DataOutputStream to the file
		var dos = new DataOutputStream (file.append_to (FileCreateFlags.NONE));
		// writing a short string to the stream
		dos.put_string (log);
	} catch (GLib.Error e) {
		GLib.stderr.printf("%s\n", e.message);
	}
}

private void cb_event (Event event, void *data1, void *data2) {
	string event_str = null;
	switch (event) {
		case Event.CHECKDEPS_START:
			event_str = _("checking dependencies...\n");
			break;
		case Event.FILECONFLICTS_START:
			event_str = _("checking for file conflicts...\n");
			break;
		case Event.RESOLVEDEPS_START:
			event_str = _("resolving dependencies...\n");
			break;
		case Event.INTERCONFLICTS_START:
			event_str = _("looking for inter-conflicts...\n");
			break;
		case Event.ADD_START:
			unowned Package pkg = (Package) data1;
			event_str = _("installing %s...\n").printf ("%s (%s)".printf (pkg.name, pkg.version));
			break;
		case Event.ADD_DONE:
			unowned Package pkg = (Package) data1;
			string log = "installed %s (%s)\n".printf (pkg.name, pkg.version);
			write_log_file (log);
			break;
		case Event.REMOVE_START:
			unowned Package pkg = (Package) data1;
			event_str = _("removing %s...\n").printf ("%s (%s)".printf (pkg.name, pkg.version));
			break;
		case Event.REMOVE_DONE:
			unowned Package pkg = (Package) data1;
			string log = "removed %s (%s)\n".printf (pkg.name, pkg.version);
			write_log_file (log);
			break;
		case Event.UPGRADE_START:
			unowned Package new_pkg = (Package) data1;
			unowned Package old_pkg = (Package) data2;
			event_str = _("upgrading %s...\n").printf ("%s (%s -> %s)".printf (old_pkg.name, old_pkg.version, new_pkg.version));
			break;
		case Event.UPGRADE_DONE:
			unowned Package new_pkg = (Package) data1;
			unowned Package old_pkg = (Package) data2;
			string log = _("upgraded %s (%s -> %s)\n").printf (old_pkg.name, old_pkg.version, new_pkg.version);
			write_log_file (log);
			break;
		case Event.DOWNGRADE_START:
			unowned Package new_pkg = (Package) data1;
			unowned Package old_pkg = (Package) data2;
			event_str = _("downgrading %s...\n").printf ("%s (%s -> %s)".printf (old_pkg.name, old_pkg.version, new_pkg.version));
			break;
		case Event.DOWNGRADE_DONE:
			unowned Package new_pkg = (Package) data1;
			unowned Package old_pkg = (Package) data2;
			string log = _("downgraded %s (%s -> %s)\n").printf (old_pkg.name, old_pkg.version, new_pkg.version);
			write_log_file (log);
			break;
		case Event.REINSTALL_START:
			unowned Package pkg = (Package) data1;
			event_str = _("reinstalling %s...\n").printf ("%s (%s)".printf (pkg.name, pkg.version));
			break;
		case Event.REINSTALL_DONE:
			unowned Package pkg = (Package) data1;
			string log = "reinstalled %s (%s)\n".printf (pkg.name, pkg.version);
			write_log_file (log);
			break;
		case Event.INTEGRITY_START:
			event_str = _("checking package integrity...\n");
			break;
		case Event.KEYRING_START:
			event_str = _("checking keyring...\n");
			break;
		case Event.KEY_DOWNLOAD_START:
			event_str = _("downloading required keys...\n");
			break;
		case Event.LOAD_START:
			event_str = _("loading package files...\n");
			break;
		case Event.DELTA_INTEGRITY_START:
			event_str = _("checking delta integrity...\n");
			break;
		case Event.DELTA_PATCHES_START:
			event_str = _("applying deltas...\n");
			break;
		case Event.DELTA_PATCH_START:
			unowned string string1 = (string) data1;
			unowned string string2 = (string) data2;
			event_str = _("generating %s with %s... ").printf (string1, string2);
			break;
		case Event.DELTA_PATCH_DONE:
			event_str = _("success!\n");
			break;
		case Event.DELTA_PATCH_FAILED:
			event_str = _("failed.\n");
			break;
		case Event.SCRIPTLET_INFO:
			unowned string info = (string) data1;
			event_str = info;
			write_log_file (event_str);
			break;
		case Event.RETRIEVE_START:
			event_str = _("Retrieving packages ...\n");
			break;
		case Event.DISKSPACE_START:
			event_str = _("checking available disk space...\n");
			break;
		case Event.OPTDEP_REQUIRED:
			unowned Package pkg = (Package) data1;
			Depend *depend = data2;
			event_str = _("%s optionally requires %s\n").printf (pkg.name, depend->compute_string ());
			break;
		case Event.DATABASE_MISSING:
			event_str =  _("database file for '%s' does not exist\n").printf ((char *) data1);
			break;
		/* all the simple done events, with fallthrough for each */
		
		case Event.FILECONFLICTS_DONE:
		case Event.CHECKDEPS_DONE:
		case Event.RESOLVEDEPS_DONE:
		case Event.INTERCONFLICTS_DONE:
		case Event.INTEGRITY_DONE:
		case Event.KEYRING_DONE:
		case Event.KEY_DOWNLOAD_DONE:
		case Event.LOAD_DONE:
		case Event.DELTA_INTEGRITY_DONE:
		case Event.DELTA_PATCHES_DONE:
		case Event.DISKSPACE_DONE:
			/* nothing */
			break;
		default:
			event_str = "unknown event";
			break;
	}
	if (event_str != null)
		server.emit_event ((uint) event, event_str);
}

private void cb_question (Question question, void *data1, void *data2, void *data3,  out int response) {
	switch (question) {
		case Question.INSTALL_IGNOREPKG:
			// Do not install package in IgnorePkg/IgnoreGroup
			response = 0;
			break;
		case Question.REPLACE_PKG:
			// Auto-remove conflicts in case of replaces
			response = 1;
			break;
		case Question.CONFLICT_PKG:
			// Auto-remove conflicts
			response = 1;
			break;
		case Question.REMOVE_PKGS:
			// Do not upgrade packages which have unresolvable dependencies
			response = 1;
			break;
		case Question.SELECT_PROVIDER:
			unowned Alpm.List<Package?> providers = (Alpm.List<Package?>) data1;
			Depend *depend = data2;
			string depend_str = depend->compute_string ();
			string[] providers_str = {};
			foreach (unowned Package pkg in providers) {
				providers_str += pkg.name;
			}
			server.provider_cond = Cond ();
			server.provider_mutex = Mutex ();
			server.choosen_provider = null;
			server.emit_providers (depend_str, providers_str);
			server.provider_mutex.lock ();
			while (server.choosen_provider == null) {
				server.provider_cond.wait (server.provider_mutex);
			}
			response = server.choosen_provider;
			server.provider_mutex.unlock ();
			break;
		case Question.CORRUPTED_PKG:
			// Auto-remove corrupted pkgs in cache
			response = 1;
			break;
		case Question.IMPORT_KEY:
			PGPKey *key = data1;
			// Do not get revoked key
			if (key->revoked == 1) response = 0;
			// Auto get not revoked key
			else response = 1;
			break;
		default:
			response = 0;
			break;
	}
}

private void cb_progress (Progress progress, string pkgname, int percent, uint n_targets, uint current_target) {
	string action = "";
	switch (progress) {
		case Progress.ADD_START:
			action = _("installing");
			break;
		case Progress.UPGRADE_START:
			action = _("upgrading");
			break;
		case Progress.DOWNGRADE_START:
			action = _("downgrading");
			break;
		case Progress.REINSTALL_START:
			action = _("reinstalling");
			break;
		case Progress.REMOVE_START:
			action = _("removing");
			break;
		case Progress.CONFLICTS_START:
			action = _("checking for file conflicts");
			break;
		case Progress.DISKSPACE_START:
			action = _("checking available disk space");
			break;
		case Progress.INTEGRITY_START:
			action = _("checking package integrity");
			break;
		case Progress.KEYRING_START:
			action = _("checking keys in keyring");
			break;
		case Progress.LOAD_START:
			action = _("loading package files");
			break;
		default:
			break;
	}
	if ((uint64) percent != server.previous_percent) {
		server.previous_percent = (uint64) percent;
		server.emit_progress ((uint) progress, action, pkgname, percent, n_targets, current_target);
	}
}

private void cb_download (string filename, uint64 xfered, uint64 total) {
	if (xfered != server.previous_percent) {
		server.previous_percent = xfered;
		server.emit_download (filename, xfered, total);
	}
}

private void cb_totaldownload (uint64 total) {
	server.emit_totaldownload (total);
}

private void cb_log (LogLevel level, string fmt, va_list args) {
	LogLevel logmask = LogLevel.ERROR | LogLevel.WARNING;
	if ((level & logmask) == 0)
		return;
	string? log = null;
	log = fmt.vprintf (args);
	if (log != null)
		server.emit_log ((uint) level, log);
}

void on_bus_acquired (DBusConnection conn) {
	server = new PamacServer ();
	try {
		conn.register_object ("/org/manjaro/pamac", server);
	}
	catch (IOError e) {
		stderr.printf ("Could not register service\n");
	}
}

void main () {
	// i18n
	Intl.setlocale(LocaleCategory.ALL, "");
	Intl.textdomain(GETTEXT_PACKAGE);

	Bus.own_name(BusType.SYSTEM, "org.manjaro.pamac", BusNameOwnerFlags.NONE,
				on_bus_acquired,
				() => {},
				() => stderr.printf("Could not acquire name\n"));

	loop = new MainLoop ();
	loop.run ();
}