#!/usr/bin/perl 
# *
# * Copyright (c) 2009 Patrik Lundin <patrik@komsi.se>
# *
# * Permission to use, copy, modify, and distribute this software for any
# * purpose with or without fee is hereby granted, provided that the above
# * copyright notice and this permission notice appear in all copies.
# *
# * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
# *

use strict;
use warnings;
use POSIX "setsid";
use IO::Socket;
use IO::Poll qw(POLLIN POLLHUP POLLERR);
use LWP::Simple;
use Time::Interval ();
use URI;
use LWP::UserAgent;
use Config::IniFiles;
use HTML::Entities;
use Encode::Encoding;

my $cfg = Config::IniFiles->new( -file => "/home/ircbot/pircc/pircc.ini" );

my $logfile = $cfg->val('pircc', 'log');
my $badwords_file = $cfg->val('pircc', 'badwords');

my $host = $cfg->val('server', 'host');
my $port = $cfg->val('server', 'port');
my $startup = 1;
my $connected = 0;
my $sock;
my $poll = IO::Poll->new;
my $pret;
my $ping_msg = "pirrc-ping-msg";
my $server_name;
my @badwords;
my $reconnTime = 10;
my $loadbadwords;

my $debug = 0;

my $nickname = $cfg->val('user', 'nickname');
my $password = $cfg->val('user', 'password');
my $realname = $cfg->val('user', 'realname');
my $channel = $cfg->val('user', 'channel');


my $startup_time = time;

sub quit_irc {
	print "Leaving IRC.\n";
	$sock->send("QUIT :It can only be attributable to human error.\r\n");
	$sock->shutdown(0) or die "close: $!";
	close LOG or die "close: $!";
	exit 1;
}

sub help {
	my $help = "cmds: !ask <yes/no question>, !dota, !g <query>, !linux, !roll, !time, !uptime";
	return $help;
}

sub ask_eightball {
	my @replys = (	"As I see it, yes",
			"Ask again later",
			"Better not tell you now",
			"Cannot predict now",
			"Concentrate and ask again",
			"Don't count on it",
			"It is certain",
			"It is decidedly so",
			"Most likely",
			"My reply is no",
			"My sources say no",
			"Outlook good",
			"Outlook not so good",
			"Reply hazy, try again",
			"Signs point to yes",
			"Very doubtful",
			"Without a doubt",
			"Yes",
			"Yes - definitely",
			"You may rely on it");
	my $rand_choice = int rand(20);
	return $replys[$rand_choice];
}

sub roll_dice {
	my $roll = int(rand 101);
}

sub get_uptime {
	my $uptime_seconds = time() - $startup_time;
	my $uptime_string = Time::Interval::parseInterval(seconds => $uptime_seconds, String => 1);
	return "uptime: $uptime_string";
}

sub check_words {
	my $string = shift;
	foreach (@badwords) {
		if ($debug == 1){
			print "Comparing \"$string\" to \"$_\"\n";
		}
		if($string =~ /$_/i){
			print "String denied: $string\n";
			return 0;
		}	
	}
	print "String accepted: $string\n";
	return $string;
}

sub get_title {
	my $url = shift;
	$url = &check_words($url);
	if ($url){
		my $content = LWP::Simple::get($url);
		if ($content) {
			my $title = $1 if $content =~ m!<title>(.*?)</title>!;
			if ($title){
				$title = decode_entities($title);
				if(Encode::is_utf8($title)){
					print "Title is UTF8!\n";
					$title = Encode::encode("iso-8859-1", $title);
				}
				return $title;
			}else {
				return 0;
			}
		} else {
			return 0;
		}
	}else {
		return 0;
	}
}

sub get_time {
	my $time = localtime;
	return "time: $time";
}

sub dota_latest {
	my $url = "http://getdota.com/";
	my $content = LWP::Simple::get($url);
	if ($content) {
		if ($content =~ m!<div class="header">Latest Map: <span class="version">(.*?)</span></div>!) {
			my $latest_map = "DotA latest map: $1";
		}
	} else {
		return 0;
	}
}

sub linux_latest {
	my $url = "http://kernel.org/";
	my $content = LWP::Simple::get($url);
	if ($content) {
		if ($content =~ m!<a href="http://www.kernel.org/pub/linux/kernel/.*?">(.*?)</a>!) {
			my $latest_linux = "Latest stable kernel: $1";
		}
	} else {
		return 0;
	}
}

sub g_search {
	my $query = shift;
	$query = &check_words($query);
	if($query){

		my $url = URI->new('http://www.google.se/search');
		$url->query_form('q' => $query);

		# Create a user agent object
		my $ua = LWP::UserAgent->new;
		$ua->agent("pircc/0.1");

		# Pass request to the user agent and get a response back
		my $res = $ua->get($url);

		# Check the outcome of the response
		if ($res->is_success) {
			my $content = $res->content;
			$content =~ m!<h3 class=r><a href="(.*?)" class=l>(.*?)</a></h3>!;
			my ($link, $title) = ($1,$2);
			$title =~ s!</?em>!!g;

			print "title: $title\nlink: $link\n";
			return ($title, $link);

		} else {
			print $res->status_line, "\n";
		}
	} else {
		return (0, 0);
	}
}

sub irc_reconnect {
	$poll->remove($sock);
	eval{
		$sock->shutdown(0);
	};
	if ($@ =~ /Transport endpoint is not connected/) {
		print "I recieved \"Transport endpoint is not connected\" on shutdown(), did you break the Internet?\n";
	}
	$connected = 0;
	$startup = 1;
}

sub get_badwords {
	@badwords = ();
	print "Loading badwords-file...\n";
	open(BADWORDS, $badwords_file) or die "Unable to open badwords-file: $!";
	while (<BADWORDS>) {
		chomp;
		if ($debug == 1){
			print "Pushing $_ into badwords-array\n";
		}
		push(@badwords, $_);
	}
	close BADWORDS;
	print "Loading complete, the following words are ignored:\n";
	foreach (@badwords){
		print "$_\n";
	}
	$loadbadwords = 0;
}

sub daemonize {
	chdir("/") or die "Can't change dir to /: $!";
	open STDIN, "< /dev/null" or die "Can't read /dev/null: $!";
	open STDOUT, "> /dev/null";
	open STDERR, ">> $logfile";
	defined(my $pid = fork)	or die "Can't fork: $!";
	exit if $pid;
	setsid() or die "Can't start a new session: $!";
	umask 0;
}

sub reload {
	print "Got SIGUP, reloading...\n";
	$loadbadwords = 1;
}

&daemonize();

open LOG, ">>", $logfile or die "open: $!";
select LOG;
$| = 1;

&get_badwords();

$SIG{HUP} = 'reload';
$SIG{TERM} = 'quit_irc';

while ($startup) {
	$startup = 0;
	while ($connected == 0) {
		eval {
			$sock = new IO::Socket::INET(
				PeerAddr => $host,
				PeerPort => $port,
				Proto => 'tcp') or die "Error creating socket: $!";
		};
		if ($@ =~ /Connection refused/) {
			$reconnTime += $reconnTime + 10;
			print "Connection refused, attempting to reconnect in $reconnTime seconds...\n";
			sleep $reconnTime;
		}
		elsif ($@ =~ /Connection timed out/) {
			$reconnTime += $reconnTime + 10;
			print "Connection timed out, attempting to reconnect in $reconnTime seconds...\n";
			sleep $reconnTime;
		}
		elsif ($@ =~ /Error creating socket/) {
			$reconnTime += $reconnTime + 10;
			print "Error creating socket, attempting to reconnect in $reconnTime seconds...\n";
			sleep $reconnTime;
		}
		elsif ($@) {
			print "There was some weird response at socket creation: $@";
			exit 1;
		}
		else {
			$reconnTime = 10;
			$connected = 1;
		}
	}

	$poll->mask($sock, POLLIN);

	print "NICK $nickname\n";
	$sock->send("NICK $nickname\r\n");
	print "USER $nickname $host $host :$realname\n";
	$sock->send("USER $nickname $host $host :$realname\r\n");
	print "MSG NICKSERV IDENTIFY PASSWORD\n";
	$sock->send("PRIVMSG nickserv :identify $password\r\n");
	sleep(3);
	print "JOIN $channel\n";
	$sock->send("JOIN $channel\r\n");

	my $r_data;
	my $readbuffer;
	my $recv_return;
	my @temp;
	my $temp = '';
	my $poll_timeout = 1;
	my $ping_sent = 0;
	my $ping_timeout;
	my $ping_wait = 55;
	my @ready;
	my $handle;
	$/ = "\r";
	while ($connected) {
		if ($loadbadwords == 1){
			{
			local $/ = "\n";
			&get_badwords();
			}
		}
		$pret = $poll->poll($poll_timeout);
		if ($pret == 0){
			if ($ping_sent == 0){
				if ($ping_wait <= 280){
					$ping_wait += 1;
				}
				else {
					print "Sending PING...\n";
					$sock->send("PING $ping_msg\r\n");
					$ping_sent = time();
					$ping_timeout = $ping_sent + 300;
					$ping_wait = 0;
				}
			}

			if ($ping_sent != 0){
				if ($ping_timeout < time()){
					print "Ping timeout occured, attempting to reconnect...\n";
					&irc_reconnect;
				}
			}
		}

		elsif ($pret == -1){
			if ($!{EINTR}){
			}
			else {
				print "An unexpected error occured: $!\n";
				print "Attempting to reconnect after poll() error...\n";
				&irc_reconnect;
			}
		}
		else {
			@ready = $poll->handles();
			foreach $handle (@ready) {
				$recv_return = sysread($handle, $readbuffer, 1024);
				if ($recv_return == 0) {
					syswrite(LOG, "No data to read on socket!: $!\n");
					syswrite(LOG, "Reconnecting...\n");
					&irc_reconnect;
				}
				elsif ($recv_return == -1){
					&irc_reconnect;syswrite(LOG, "Error on socket read: $!");
					syswrite(LOG, "Reconnecting...\n");
					&irc_reconnect;
				}
				else {
					$temp .= $readbuffer;
					print "\$temp = $temp";
					@temp = split /\n/, $temp;
					if ($temp =~ /\n$/) {
						push @temp, "";
					}
					$temp = pop @temp;
					
					if (@temp) {
						foreach $r_data (@temp) {
							chomp($r_data);
							print "\$r_data = $r_data\n";
							if ($r_data =~ /:(.*?) NOTICE AUTH :\*\*\* Looking up your hostname.../) {
								$server_name = $1;
							}
							if ($r_data =~ /^PING :([\w|\.]+)/) {
								print "Got PING from $1, sending PONG reply.\n";
								$sock->send("PONG $1\r\n");
							}
							if ($r_data =~ /^:$server_name PONG $server_name :$ping_msg/) {
								print "Got PONG from server, resetting \$ping_sent.\n";
								$ping_sent = 0;
							}
							if ($r_data =~ /:(.*?)!.*?PRIVMSG (.\w+) :!g (.+)$/) {
								my $g_nick = $1;
								my $g_chnl = $2;
								my $g_query = $3;
								$g_query =~ s/\s/+/g;
								my ($g_title, $g_link) = &g_search($g_query);
								if ($g_title) {
									print "g_query = $g_query\n";
									print "PRIVMSG $g_chnl :$g_nick: $g_title -> $g_link\n";
									$sock->send("PRIVMSG $g_chnl :$g_nick: $g_title -> $g_link\r\n");
								} else {
									print "Google-fail:\ng_query: $g_query\ng_title: $g_title\ng_link: $g_link\n";
								}
							}
							if ($r_data =~ /:eest!Brock\@hamster-BBB5D54E.virtality.se PRIVMSG (#linux) :!kick (.*)/){
								print "KICK $1 $2:Ut med dig!\n";
								$sock->send("KICK $1 $2:Ut med dig!\r\n");
							}
							if ($r_data =~ /^:([^!]*).* (#linux) :\w+\s*~\s?.*/){
								my $rand = int(rand(2));
								if ($rand) {
									print "KICK $2 $1: Gotcha!\n";
									$sock->send("PRIVMSG $2 :$1: Gotcha!\r\n");
									$sock->send("KICK $2 $1 :Gotcha!\r\n");
								} else {
									print "You got lucky!\n";
									$sock->send("PRIVMSG $2 :$1: You got lucky!\r\n");

								}
							}
							if ($r_data =~ /:(.*?)!.*?PRIVMSG (.\w+) :!ask /) {
								my $response = &ask_eightball();
								print "The response is: $response\n";
								$sock->send("PRIVMSG $2 :$1: $response\r\n");
							}
							if ($r_data =~ /:(.*?)!.*?PRIVMSG (.\w+) :!help$/) {
								my $response = &help();
								print "Help message: $response\n";
								$sock->send("PRIVMSG $1 :$response\r\n");
							}
							if ($r_data =~ /:(.*?)!.*?PRIVMSG (.\w+) :!roll$/) {
								my $response = &roll_dice();
								print "Roll is $response\n";
								$sock->send("PRIVMSG $2 :$1: $response\r\n");
							}
							if ($r_data =~ /:(.*?)!.*?PRIVMSG (.\w+) :!uptime$/) {
								my $response = &get_uptime();
								print "$response\n";
								$sock->send("PRIVMSG $2 :$response\r\n");
							}
							if ($r_data =~ /:(.*?)!.*?PRIVMSG (.\w+) :!time$/) {
								my $response = &get_time();
								print "$response\n";
								$sock->send("PRIVMSG $2 :$response\r\n");
							}
							if ($r_data =~ /:(.*?)!.*?PRIVMSG (.\w+) :!dota$/) {
								my $response = &dota_latest();
								print "$response\n";
								$sock->send("PRIVMSG $2 :$response\r\n");
							}
							if ($r_data =~ /:(.*?)!.*?PRIVMSG (.\w+) :!linux$/) {
								my $response = &linux_latest();
								print "$response\n";
								$sock->send("PRIVMSG $2 :$response\r\n");
							}
							if ($r_data =~ /:(.*?)!.*?PRIVMSG (.\w+) :(http:\/\/[^ ]*)$/) {
								my $response = &get_title($3);
								if ($response) {
									print "$response\n";
									$sock->send("PRIVMSG $2 :$1's URL title: $response\r\n");
								}
							}
							if ($r_data =~ /ERROR :Closing Link:/) {
								print "I died: $r_data\n";
								print "Reconnecting...\n";
								&irc_reconnect;
							}
						} 
					} else {
						print "\@temp = @temp";
					}
				}
			}
		}
	}
}
$sock->shutdown(0) or die "close: $!";
close LOG or die "close: $!";
