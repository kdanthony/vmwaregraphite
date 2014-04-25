VMwareGraphite.pl
========
Connects to vCenter and gets a list of VMware hosts. Connects to each and collects performance stats. Passes those on to graphite. Very simple right now but the idea was just a quick and dirty way to get the stats into graphite.

Quick Setup:

* Unpack and install the VMware Perl SDK
* Install CPAN modules: Parallel::ForkManager, Time::HiRes
* Modify use lib to point to VMware Perl SDK path and update the graphite configuration section.
* ./vmwaregraphite.pl --url=https://vcenterhostname/sdk/vimService --username=username --password=password
* If you want to store the credentials setup a credential store using credstore_admin.pl in the Perl SDK.

TODO:

* Better error correction
* Eliminate the remaining VMware code.
