#!/usr/bin/env perl

###     #     #####   #####
# #    # #      #       #
###   #####     #       #
#    #     #    #       #
# [P]ut [A]ll [T]he [T]hings!!!@#!%$!@
#
# PATT & PATT_that
# (c) 2012 Michael Gregorowicz.  All rights reserved.  This program
# is free software; you can redistribute it and/or modify it under
# the same terms as Perl itself.
#
# PATT does 3 things.  It does them very carefully.
# (1) lets you put anything you want at any /location/on/
# (2) makes sure no one can go snooping around the namespace for stuff
# (3) keeps the sysadmin from knowing anything about the content they're hosting
#
# quick list of deps: Mojolicious, Crypt::CBC, Digest::SHA2, Crypt::Twofish, Net::INET6Glue
# don't have Perl?  run: curl -kL http://install.perlbrew.pl | bash

unless ($ARGV[0]) {
    die "Usage: patt.pl <listen scheme> e.g. https://*:8443\n";
}

# we need this for IPv6 support, if you don't need IPv6, comment this out.
BEGIN { use Net::INET6Glue }

# Debugging.  What it be?
my $DEBUG = 0;

# configuration.
my $c = {
    freebees => 300,
    freebee_period => 600,
    flat_ppi => 5,
    ppi_modifier => .01,
    cipher => 'Twofish',
    max_poll_seqnos => 50,
};
# do this up top 
use Crypt::Twofish;

# PATT uses Mojolicious, the sweet new framework for Perl by sri!
use Mojo::Server::Daemon;
my $httpd = Mojo::Server::Daemon->new(
    listen => [split(',', $ARGV[0])],
    user => $ARGV[1] ? $ARGV[1] : '',
#    group => 'nobody',
);

# this is where we keep our content.. in files named as hashes :)
use Digest::SHA2;
my $sha2 = new Digest::SHA2 256;

# data dumper
use Data::Dumper;
local $Data::Dumper::Terse = 1;

# crypto for keeping file data safe!
use Crypt::CBC;

# keep state here.
my $state = read_and_eval('patt.dat');

unless (-d "things") {
    mkdir("things");
}

# redefine the request handler
$httpd->unsubscribe('request');
$httpd->on(request => sub {
    my ($httpd, $tx) = @_;

    my $req = $tx->req;

    $tx->res->headers->parse("Access-Control-Allow-Origin: *\n\n");

    # no favicon.ico or robots.txt.
    if ($req->url->path =~ /\/*(?:robots.txt|favicon.ico)$/) {
        $tx->res->code(404);
        $tx->res->headers->content_type('text/plain');
        $tx->res->body("Not found");
    } else {
        # figure out what this is!
        my $op = $req->param('op');
        $op = lc($op);
        $op = "get" unless $op;

        my $url = $req->url->to_abs;
        my $abs_url;
        if ($url->port && ($url->port != 80 && $url->port != 443)) {
            $abs_url = sprintf("%s://%s:%d%s", $url->scheme, $url->host, $url->port, $url->path);
        } else {
            $abs_url = sprintf("%s://%s%s", $url->scheme, $url->host, $url->path);
        }

        # obtain teh hash for the resource we're getting.
        $sha2->add($abs_url);
        # rname = "resource name"
        my $rname = $sha2->hexdigest;
        $sha2->reset();

        my $reverse_url = reverse($abs_url);
        
        # obtain teh key for the resources we'll be encrypting on disk.
        $sha2->add($reverse_url);
        # skey = "secret key"
        my $skey = $sha2->hexdigest;
        $sha2->reset();

        # set up the cipher.
        my $cipher = Crypt::CBC->new(
            -key => substr($skey, 4, 32),
            -cipher => $c->{cipher},
            -salt => 1,
        );

        if ($op eq "get") {
            if (-e "things/$rname.dat") {
                # we have a metadata file, let's read it!
                my $md = read_and_eval("things/$rname.dat", $cipher);
                my $tts = time_til_served($tx->remote_address);

                # if we're in timeout, or if we're accessing expired content, let's penalize
                if ($md->{feed} || $tts || (exists $md->{expiration_time} && time > $md->{expiration_time})) {
                    register_failure($tx->remote_address);
                    my $tts = time_til_served($tx->remote_address);
                    $tx->res->code(200);
                    $tx->res->headers->content_type('text/plain');
                    $tx->res->body("[bad]: beeeeeeeeeeep.  errrrrrrrrrrt.  penalty. ($tts)");

                    # fixup, cleanup!
                    if (exists $md->{expiration_time} && time > $md->{expiration_time}) {
                        unlink("things/$rname.dat");
                        unlink("things/$rname");
                    }
                } else {
                    # this is a response we can respond to :)
                    $cipher->start('decrypt');
                    my ($buff, $bytes, $data);
                    open(PATTFILE, '<', "things/$rname") or die "Can't open things/$rname for reading: $!\n";
                    while (read PATTFILE, $data, 1024000) {
                        my $plain = $cipher->crypt($data);
                        $bytes += length($plain);
                        if (($buff . $plain) =~ /\r\n/) {
                            # we can process a chunk.
                            my (@lines) = split(/\r\n/, ($buff . $plain));
                            foreach my $line (@lines[0..$#lines -1 ]) {
                                $tx->res->parse($line . "\r\n");
                                if ($DEBUG) {
                                    if ($line =~ /^[\w\-]+: /) {
                                        print "HTTP HEADER: $line\n";
                                    }
                                }
                            }
                            # reset what buff is
                            $buff = $lines[$#lines];
                            #warn "setting what buff is: '$buff'\n";

                        } else {
                            $buff .= $plain;
                        }
                        warn "Bytes parsed: $bytes\n" if $DEBUG;
                    }
                    # process whatever's left after all the crypto is done.
                    $buff .= $cipher->finish;
                    $bytes += length($buff);
                    warn "Total bytes parsed: $bytes\n" if $DEBUG;
                    $tx->res->parse($buff);
                    warn "Done parsing HTTP Response content.\n" if $DEBUG;
                    close(PATTFILE);
                }
            } else {
                register_failure($tx->remote_address);
                my $tts = time_til_served($tx->remote_address);
                $tx->res->code(200);
                $tx->res->headers->content_type('text/plain');
                $tx->res->body("[bad]: beeeeeeeeeeep.  errrrrrrrrrrt.  penalty. ($tts)");
            }
        } elsif ($op eq "put") {
            # upload data
            my $md = {};
            if (-e "things/$rname.dat") {
                $md = read_and_eval("things/$rname.dat", $cipher);
            }

            if (!$md->{feed} && $md->{protect_until} < time && $req->method eq "POST" && $req->upload('f')) {
                my $upload = $req->upload('f');
                my $filename = $upload->filename;
                my $content_type = $upload->headers->content_type;
                my $asset = $upload->asset;
                my $wrote_file = 0;
                my $chunk = $asset->get_chunk(0);

                if ($chunk =~ /^HTTP/) {
                    # we can save this as it is.
                    open(PATTWRITE, '>', "things/$rname");
                    if ($asset->is_file) {
                        print PATTWRITE $cipher->encrypt($chunk);
                        my $fh = $asset->handle;
                        while (my $line = <$fh>) {
                            print PATTWRITE $cipher->encrypt($line);
                        }
                        $asset->cleanup(1);
                    } else {
                        print PATTWRITE $cipher->encrypt($asset->slurp);
                    }
                    close(PATTWRITE);
                } else {
                    # we need to generate a message for it.
                    $headers = Mojo::Headers->new;
                    $headers->content_length($asset->size);
                    $headers->content_type($content_type);
                    $headers->date(Mojo::Date->new->to_string);

                    $header_replay = "HTTP/1.1 200 OK\r\n";
                    $header_replay .= $headers->to_string;
                    $header_replay .= "\r\n\r\n";

                    warn "Header replay-------\n" if $DEBUG;
                    warn "$header_replay" if $DEBUG;
                    warn "--------------------\n" if $DEBUG;

                    open(PATTWRITE, '>', "things/$rname");
                    $cipher->start('encrypting');
                    print PATTWRITE $cipher->crypt($header_replay);
                    if ($asset->is_file) {
                        warn "Asset is file!\n" if $DEBUG;
                        my $fh = $asset->handle;
                        binmode $fh;

                        # encrypt the chunk
                        my $chunk_ct = $cipher->crypt($chunk);
                        my $crypto_bytes_written = length($chunk_ct);
                        my $cleartext_bytes_written = length($chunk);
                        print PATTWRITE $chunk_ct;

                        while (my $line = <$fh>) {
                            my $ct = $cipher->crypt($line);
                            $crypto_bytes_written += length($ct);
                            $cleartext_bytes_written += length($line);
                            print PATTWRITE $ct;
                        }
                        warn "header replay length: " . length($header_replay) . "\n" if $DEBUG;
                        warn "clear bytes: $cleartext_bytes_written\n" if $DEBUG;
                        warn "crypto bytes: $crypto_bytes_written\n" if $DEBUG;
                        warn "asset size: " . $asset->size . "\n" if $DEBUG;
                        $asset->cleanup(1);
                    } else {
                        print PATTWRITE $cipher->crypt($asset->slurp);
                    }
                    print PATTWRITE $cipher->finish;
                    close(PATTWRITE);
                }

                # compute expire time (sorry for copy & paste)
                if (my $expires_in = $req->param('expires_in')) {
                    $md->{expiration_time} = now_plus_denom($expires_in);
                }

                # this is how long we protect this for
                if (my $protect_for = $req->param('protect_for')) {
                    $md->{protect_until} = now_plus_denom($protect_for);
                }

                serialize_and_write($md, "things/$rname.dat", $cipher);
            } elsif (!$md->{feed} && $md->{protect_until} < time && $req->param('v')) {
                my $v = $req->param('v');
                if ($v =~ /^HTTP/) {
                    open(PATTWRITE, '>', "things/$rname");
                    print PATTWRITE $cipher->encrypt($v);
                    close(PATTWRITE);
                } else {
                    my $res = Mojo::Message::Response->new;
                    open(PATTWRITE, '>', "things/$rname");
                    $res->code(200);
                    $res->headers->content_type('text/plain');
                    $res->body($v);
                    print PATTWRITE $cipher->encrypt($res->to_string);
                    close(PATTWRITE);
                }
                my $md = {};
                if (my $expires_in = $req->param('expires_in')) {
                    # $md->{expiration_time}
                    $md->{expiration_time} = now_plus_denom($expires_in);
                }

                if (my $protect_for = $req->param('protect_for')) {
                    $md->{protect_until} = now_plus_denom($protect_for);
                }

                serialize_and_write($md, "things/$rname.dat", $cipher);
            } else {
                register_failure($tx->remote_address);
            }
            $tx->res->code(302);
            $tx->res->headers->location($abs_url);
        } elsif ($op eq "establish_feed") {
            if (-d "things/$rname") {
                my $md = read_and_eval("things/$rname.dat", $cipher);
                my $tts = time_til_served($tx->remote_address);
                if (!$md->{feed} || $tts || (exists $md->{expiration_time} && time > $md->{expiration_time})) {
                    register_failure($tx->remote_address);
                }
                $tx->res->code(200);
                $tx->res->headers->content_type('text/plain');
                $tx->res->body("[bad]: beeeeeeeeeeep.  errrrrrrrrrrt.  penalty. ($tts)");
            } else {
                mkdir("things/$rname");
                # populate metadata, feeds can expire but never re-init.
                my $md = {feed => 1};
                if (my $expires_in = $req->param('expires_in')) {
                    # $md->{expiration_time}
                    $md->{expiration_time} = now_plus_denom($expires_in);
                }

                serialize_and_write($md, "things/$rname.dat", $cipher);
                $tx->res->code(200);
                $tx->res->headers->content_type('text/plain');
                $tx->res->body("[good]: wrrrrtttt.  chrkachrkachrka.  weeeeeeeet.  op successful.");
            }
        } elsif ($op eq "poll_feed" && $req->param('pos')) {
            if (-d "things/$rname") {
                my $md = read_and_eval("things/$rname.dat", $cipher);
                my $tts = time_til_served($tx->remote_address);
                if (!$md->{feed} || $tts || (exists $md->{expiration_time} && time > $md->{expiration_time})) {
                    register_failure($tx->remote_address);
                    $tx->res->code(200);
                    $tx->res->headers->content_type('text/plain');
                    $tx->res->body("[bad]: beeeeeeeeeeep.  errrrrrrrrrrt.  penalty. ($tts)");
                } else {
                    my $body;
                    my $json = Mojo::JSON->new;
                    my $return_payload = { seqnos => [] };
                    if ($req->param('pos') eq "last") {
                        $req->param('pos', next_feed_seqno("things/$rname", 100000) - 1);
                    }
                    for (my $i = $req->param('pos'); $i < $req->param('pos') + $c->{max_poll_seqnos}; $i++) {
                        if (-e "things/$rname/$i" ) {
                            open(PATTREAD, '<', "things/$rname/$i");
                            {
                                local $/;
                                push(@{$return_payload->{seqnos}}, $json->decode($cipher->decrypt(<PATTREAD>))); 
                            }
                            close(PATTREAD);
                        } else {
                            last;
                        }
                    }

                    $body = $json->encode($return_payload);

                    # good request!
                    $tx->res->code(200);

                    if ($body) {
                        $tx->res->headers->content_type('text/plain');
                        $tx->res->body($body);
                    } else {
                        $tx->res->headers->content_type('text/html');
                        $tx->res->body('<html><head><meta http-equiv="refresh" content="5"/></head><body></body></html>');
                    }
                }
            } else {
                register_failure($tx->remote_address);
                $tx->res->code(200);
                $tx->res->headers->content_type('text/plain');
                $tx->res->body("[bad]: beeeeeeeeeeep.  errrrrrrrrrrt.  penalty. ($tts)");
            }
        } elsif ($op eq "append_feed" && $req->param('v')) {
            my $json = Mojo::JSON->new;
            my $md = {};
            if (-e "things/$rname.dat") {
                $md = read_and_eval("things/$rname.dat", $cipher);
            }
            my $next_seqno = next_feed_seqno("things/$rname", 100000);
            my $v = $req->param('v');
            open(PATTWRITE, '>', "things/$rname/$next_seqno");
            print PATTWRITE $cipher->encrypt($json->encode({seqno => $next_seqno, payload => $v}));
            close(PATTWRITE);

            # redirect to a poll event.
            $tx->res->code(302);
            $tx->res->headers->location($abs_url . "?op=poll_feed&pos=$next_seqno");
        }

        $state->{requests_handled}++;
        unless ($state->{requests_handled} % 200 && !$DEBUG) {
            serialize_and_write($state, 'patt.dat');
        }
    }

    # give it back to the event emitter guy
    $tx->resume;
});

# start the daemon :)
$httpd->run;

sub next_feed_seqno {
    my ($feed_dir, $multiplier, $last_found) = @_;
    my $recently_found;
    for (1..100) {
        my $seqno;
        if ($last_found) {
            $seqno = $_ * $multiplier + $last_found;
        } else {
            $seqno = $_ * $multiplier;
        }
        if (-e "$feed_dir/$seqno") {
            # on the right path.  next.
            $recently_found = $seqno;
            next;
        } else {
            if ($multiplier == 1) {
                if (-e ("$feed_dir/" . ($seqno - 1))) {
                    return $seqno;
                } else {
                    return 1;
                }
            } else {
                $recently_found = $last_found unless $recently_found;
                return next_feed_seqno($feed_dir, $multiplier / 10, $recently_found);
            }
        }
    }
}

sub now_plus_denom {
    my ($source) = @_;
    my ($int, $denom) = $source =~ /^(\d+)([a-z]*)$/;
    if ($denom eq "d") {
        # days
        $int *= 86400;
    } elsif ($denom eq "h") {
        # hours
        $int *= 3600;
    } elsif ($denom eq "m") {
        # minutes
        $int *= 60;
    } elsif ($denom eq "y") {
        # years
        $int *= 31536000;
    }
    return time + $int;
}

sub register_failure {
    my ($remote_addr) = @_;
    push(@{$state->{$remote_addr}->{failtimes}}, time);
    delete($state->{$remote_addr}->{in_fail});
}

sub time_til_served {
    my ($remote_addr) = @_;

    # check to see if we're already serving a sentence in timeout!
    if ($state->{$remote_addr}->{in_fail} > time) {
        my $total = scalar(@{$state->{$remote_addr}->{failtimes}});
        my $flat_secs = $c->{flat_ppi} * $total;
        my $bonus_penalty = int($flat_secs * ($total * $c->{ppi_modifier}));
        warn "Total Violations: $total, Flat Penalty: $flat_secs, Bonus Penalty: $bonus_penalty\n" if $DEBUG;
        $state->{$remote_addr}->{in_fail} = time + $flat_secs + $bonus_penalty;
        return $state->{$remote_addr}->{in_fail} - time;
    } elsif ($state->{$remote_addr}->{in_fail}) {
        return 0;
    }

    my $min = time - $c->{freebee_period};
    
    # flat_ppi = seconds to add per violation once we've passed freebees
    # ppi_modifier = add this * # of total violations ever * the sum of the flat_ppis as a penalty

    my $over = 0;

    # first get the number of failures in this period.  don't need to build any more arrays.
    # just evaluate and count.
    foreach my $fail (@{$state->{$remote_addr}->{failtimes}}) {
        if ($fail >= $min) {
            $over++;
            last if $over > $c->{freebees};
        }
    }

    if ($over > $c->{freebees}) {
        # we're in violation!
        my $total = scalar(@{$state->{$remote_addr}->{failtimes}});
        my $flat_secs = $c->{flat_ppi} * $total;
        my $bonus_penalty = int($flat_secs * ($total * $c->{ppi_modifier}));
        warn "Total Violations: $total, Flat Penalty: $flat_secs, Bonus Penalty: $bonus_penalty\n" if $DEBUG;
        $state->{$remote_addr}->{in_fail} = time + $flat_secs + $bonus_penalty;
        return $state->{$remote_addr}->{in_fail} - time;
    }

    return 0;
}

sub read_and_eval {
    my ($file, $cipher) = @_;
    if (-e $file) {
        my $to_eval;
        open(RFILE, '<', $file) or die "read_and_eval() can't open file $file for reading: $!\n";
        {
            local $/;
            $to_eval = <RFILE>;
        }
        close(RFILE);
        if ($cipher) {
            return eval $cipher->decrypt($to_eval);
        } else {
            return eval $to_eval;
        }
    } else {
        return {};
    }
}

sub serialize_and_write {
    my ($struct, $file, $cipher) = @_;
    open(WFILE, '>', $file) or die "serialize_and_write() can't open file $file for writing: $!\n";
    if ($cipher) {
        print WFILE $cipher->encrypt(Dumper($struct));
    } else {
        print WFILE Dumper($struct);
    }
    close(WFILE);
}

