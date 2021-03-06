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

namespace Alpm {
	class Repo {
		public string name;
		public SigLevel siglevel;
		public string[] urls;

		public Repo (string name) {
			this.name = name;
			urls = {};
		} 
	}

	public class Config {
		string rootdir;
		string dbpath;
		string gpgdir;
		string logfile;
		string arch;
		double deltaratio;
		int usesyslog;
		int checkspace;
		string[] cachedir;
		string[] ignoregroup;
		string[] ignorepkg;
		string[] noextract;
		string[] noupgrade;
		string[] holdpkg;
		string[] syncfirst;
		SigLevel defaultsiglevel;
		SigLevel localfilesiglevel;
		SigLevel remotefilesiglevel;
		Repo[] repo_order;

		public Config (string path) {
			rootdir = "/";
			dbpath = "/var/lib/pacman";
			gpgdir = "/etc/pacman.d/gnupg/";
			logfile = "/var/log/pacman.log";
			arch = Posix.utsname().machine;
			cachedir = {"/var/cache/pacman/pkg/"};
			holdpkg = {};
			syncfirst = {};
			ignoregroup = {};
			ignorepkg = {};
			noextract = {};
			noupgrade = {};
			usesyslog = 0;
			checkspace = 0;
			deltaratio = 0.7;
			defaultsiglevel = SigLevel.PACKAGE | SigLevel.PACKAGE_OPTIONAL | SigLevel.DATABASE | SigLevel.DATABASE_OPTIONAL;
			localfilesiglevel = SigLevel.USE_DEFAULT;
			remotefilesiglevel = SigLevel.USE_DEFAULT;
			repo_order = {};
			// parse conf file
			parse_file (path);
		}

		public string[] get_syncfirst () {
			return syncfirst;
		}

		public string[] get_holdpkg () {
			return holdpkg;
		}

		public string[] get_ignore_pkgs () {
			string[] ignore_pkgs = {};
			unowned Group? group = null;
			Handle? handle = this.get_handle ();
			if (handle != null) {
				foreach (string name in ignorepkg)
					ignore_pkgs += name;
				foreach (string grp_name in ignoregroup) {
					group = handle.localdb.get_group (grp_name);
					if (group != null) {
						foreach (unowned Package found_pkg in group.packages)
							ignore_pkgs += found_pkg.name;
					}
				}
			}
			return ignore_pkgs;
		}

		public Handle? get_handle () {
			Alpm.Errno error;
			Handle? handle = new Handle (rootdir, dbpath, out error);
			if (handle == null) {
				stderr.printf ("Failed to initialize alpm library" + " (%s)\n".printf(Alpm.strerror (error)));
				return handle;
			}
			// define options
			handle.gpgdir = gpgdir;
			handle.logfile = logfile;
			handle.arch = arch;
			handle.deltaratio = deltaratio;
			handle.usesyslog = usesyslog;
			handle.checkspace = checkspace;
			handle.defaultsiglevel = defaultsiglevel;
			handle.localfilesiglevel = localfilesiglevel;
			handle.remotefilesiglevel = remotefilesiglevel;
			foreach (string dir in cachedir)
				handle.add_cachedir (dir);
			foreach (string name in ignoregroup)
				handle.add_ignoregroup (name);
			foreach (string name in ignorepkg)
				handle.add_ignorepkg (name);
			foreach (string name in noextract)
				handle.add_noextract (name);
			foreach (string name in noupgrade)
				handle.add_noupgrade (name);
			// register dbs
			foreach (Repo repo in repo_order) {
				unowned DB db = handle.register_syncdb (repo.name, repo.siglevel);
				foreach (string url in repo.urls) {
					db.add_server (url.replace ("$repo", repo.name).replace ("$arch", handle.arch));
				}
			}
			return handle;
		}

		public void parse_file (string path, string? section = null) {
			string current_section = section;
			var file = GLib.File.new_for_path (path);
			if (file.query_exists () == false)
				GLib.stderr.printf ("File '%s' doesn't exist.\n", file.get_path ());
			else {
				try {
					// Open file for reading and wrap returned FileInputStream into a
					// DataInputStream, so we can read line by line
					var dis = new DataInputStream (file.read ());
					string line;
					// Read lines until end of file (null) is reached
					while ((line = dis.read_line (null)) != null) {
						line = line.strip ();
						if (line.length == 0) continue;
						if (line[0] == '#') continue;
						if (line[0] == '[' && line[line.length-1] == ']') {
							current_section = line[1:-1];
							if (current_section != "options") {
								Repo repo = new Repo (current_section);
								repo.siglevel = defaultsiglevel;
								repo_order += repo;
							}
							continue;
						}
						string[] splitted = line.split ("=");
						string _key = splitted[0].strip ();
						string _value = null;
						if (splitted[1] != null)
							_value = splitted[1].strip ();
						if (_key == "Include")
							parse_file (_value, current_section);
						if (current_section == "options") {
							if (_key == "GPGDir")
								gpgdir = _value;
							else if (_key == "LogFile")
								logfile = _value;
							else if (_key == "Architecture") {
								if (_value == "auto")
									arch = Posix.utsname ().machine;
								else
									arch = _value;
							} else if (_key == "UseDelta")
								deltaratio = double.parse (_value);
							else if (_key == "UseSysLog")
								usesyslog = 1;
							else if (_key == "CheckSpace")
								checkspace = 1;
							else if (_key == "SigLevel")
								defaultsiglevel = define_siglevel (defaultsiglevel, _value);
							else if (_key == "LocalSigLevel")
								localfilesiglevel = merge_siglevel (defaultsiglevel, define_siglevel (localfilesiglevel, _value));
							else if (_key == "RemoteSigLevel")
								remotefilesiglevel = merge_siglevel (defaultsiglevel, define_siglevel (remotefilesiglevel, _value));
							else if (_key == "HoldPkg") {
								foreach (string name in _value.split (" ")) {
									holdpkg += name;
								}
							} else if (_key == "SyncFirst") {
								foreach (string name in _value.split (" ")) {
									syncfirst += name;
								}
							} else if (_key == "CacheDir") {
								foreach (string dir in _value.split (" ")) {
									cachedir += dir;
								}
							} else if (_key == "IgnoreGroup") {
								foreach (string name in _value.split (" ")) {
									ignoregroup += name;
								}
							} else if (_key == "IgnorePkg") {
								foreach (string name in _value.split (" ")) {
									ignorepkg += name;
								}
							} else if (_key == "Noextract") {
								foreach (string name in _value.split (" ")) {
									noextract += name;
								}
							} else if (_key == "NoUpgrade") {
								foreach (string name in _value.split (" ")) {
									noupgrade += name;
								}
							}
						} else {
							foreach (Repo _repo in repo_order) {
								if (_repo.name == current_section) {
									if (_key == "Server")
										_repo.urls += _value;
									else if (_key == "SigLevel")
										_repo.siglevel = define_siglevel (defaultsiglevel, _value);
								}
							}
						}
					}
				} catch (GLib.Error e) {
					GLib.stderr.printf("%s\n", e.message);
				}
			}
		}

		public SigLevel define_siglevel (SigLevel default_level, string conf_string) {
			foreach (string directive in conf_string.split(" ")) {
				bool affect_package = false;
				bool affect_database = false;
				if ("Package" in directive) affect_package = true;
				else if ("Database" in directive) affect_database = true;
				else {
					affect_package = true;
					affect_database = true;
				}
				if ("Never" in directive) {
					if (affect_package) {
						default_level &= ~SigLevel.PACKAGE;
						default_level |= SigLevel.PACKAGE_SET;
					}
					if (affect_database) default_level &= ~SigLevel.DATABASE;
				}
				else if ("Optional" in directive) {
					if (affect_package) {
						default_level |= SigLevel.PACKAGE;
						default_level |= SigLevel.PACKAGE_OPTIONAL;
						default_level |= SigLevel.PACKAGE_SET;
					}
					if (affect_database) {
						default_level |= SigLevel.DATABASE;
						default_level |= SigLevel.DATABASE_OPTIONAL;
					}
				}
				else if ("Required" in directive) {
					if (affect_package) {
						default_level |= SigLevel.PACKAGE;
						default_level &= ~SigLevel.PACKAGE_OPTIONAL;
						default_level |= SigLevel.PACKAGE_SET;
					}
					if (affect_database) {
						default_level |= SigLevel.DATABASE;
						default_level &= ~SigLevel.DATABASE_OPTIONAL;
					}
				}
				else if ("TrustedOnly" in directive) {
					if (affect_package) {
						default_level &= ~SigLevel.PACKAGE_MARGINAL_OK;
						default_level &= ~SigLevel.PACKAGE_UNKNOWN_OK;
						default_level |= SigLevel.PACKAGE_TRUST_SET;
					}
					if (affect_database) {
						default_level &= ~SigLevel.DATABASE_MARGINAL_OK;
						default_level &= ~SigLevel.DATABASE_UNKNOWN_OK;
					}
				}
				else if ("TrustAll" in directive) {
					if (affect_package) {
						default_level |= SigLevel.PACKAGE_MARGINAL_OK;
						default_level |= SigLevel.PACKAGE_UNKNOWN_OK;
						default_level |= SigLevel.PACKAGE_TRUST_SET;
					}
					if (affect_database) {
						default_level |= SigLevel.DATABASE_MARGINAL_OK;
						default_level |= SigLevel.DATABASE_UNKNOWN_OK;
					}
				}
				else GLib.stderr.printf("unrecognized siglevel: %s\n", conf_string);
			}
			default_level &= ~SigLevel.USE_DEFAULT;
			return default_level;
		}

		public SigLevel merge_siglevel (SigLevel base_level, SigLevel over_level) {
			if ((over_level & SigLevel.USE_DEFAULT) != 0) over_level = base_level;
			else {
				if ((over_level & SigLevel.PACKAGE_SET) == 0) {
					over_level |= base_level & SigLevel.PACKAGE;
					over_level |= base_level & SigLevel.PACKAGE_OPTIONAL;
				}
				if ((over_level & SigLevel.PACKAGE_TRUST_SET) == 0) {
					over_level |= base_level & SigLevel.PACKAGE_MARGINAL_OK;
					over_level |= base_level & SigLevel.PACKAGE_UNKNOWN_OK;
				}
			}
			return over_level;
		}
	}
}
