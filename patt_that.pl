#!/usr/bin/env perl
#
#
# PATT that!
# A command line client for Put All The Things!
# 
# PATT & PATT_that
# (c) 2012 Michael Gregorowicz.  All rights reserved.  This program
# is free software; you can redistribute it and/or modify it under
# the same terms as Perl itself.
#

use File::MimeInfo;
use Data::UUID;
use Getopt::Std;
use Mojo::Template;
use Mojo::UserAgent;

my $opts = {};
getopts('rvnp:H:m:e:u:i:', $opts);

# -r recursive
# -v verbose
# -n noindex (don't generate an "index.html", this file owns the / of your PATT) 
# -p protect-for (int or 1m 1h 1d 1y)
# -e expires-in (int or 1m 1h 1d 1y)
# -H patt-root-uri
# -m force-mime-type (doesn't include indexes)
# -u number-of-uuids in the location (default 2)
# -i comma delimited ignore list

unless ($ARGV[0]) {
    die "Usage: patt_that.pl -H <patt-root-uri> -p <protect_for> -e <expires_in> -m <forced mime type> -u <number-of-uuids> -i <ignore> -r -v -n <files_to_patt>\n";
}

unless ($opts->{H} || $ENV{PATT_HOST}) {
    die "Where ur PATT at?!  Must include -H <patt-root-uri> or set PATT_HOST to your PATT instance.\n";
}

# default uuid #!
$opts->{u} = defined($opts->{u}) ? $opts->{u} : 2;
$opts->{u} > 3 ? 3 : $opts->{u};

# default protect && expire
$opts->{e} ||= '1h';
$opts->{p} ||= '1h';

# explode the comma delmited ignore list
$opts->{i} = [split(/\s*,\s*/, $opts->{i})];

# explode the mime type -m into pairs to support file extensions
my $m_string = $opts->{m};
if ($m_string) {
    foreach my $pair (split(/\s*,\s*/, $m_string)) {
        my @pa = split(/=/, $pair);
        $opts->{m}->{$pa[0]} = $pa[1];
    }
} else {
    $opts->{m} = {};
}

my $patt_base = $opts->{H} || $ENV{PATT_HOST};
my $this_patt_at = $patt_base . join('/', map { new_uuid() } (1..$opts->{u}));
#warn "[info]: this patt at $this_patt_at\n";

# pull in the template from the bottom of patt_that.pl!
my $template_string;
{
    local $/;
    $template_string = <main::DATA>;
}

my @to_process;
# parse out these files and clean up leading ./
foreach my $file (@ARGV) {
    # fixup directories with leading ./
    $file =~ s/^\.\///g;
    push(@to_process, $file);
}

# an experiment with parallel uploading
my $upload_list = {};
    
my $files_created = [];
my $patted_something = 0;
my $used_root_namespace = 0;

if ($opts->{n} && $opts->{r}) {
    die "[error]: Can't use both recursive option and noindex option!  To specify your own index.html, use -r and put an index.html file in your pwd.\n";
}

if ($opts->{n}) {
    # first only, no index!
    if (-d $to_process[0]) {
        die "[error]: Can't use -n option on a directory.  File resource only!\n";
    }
    patt_this($to_process[0]);
    $patted_something = 1;
    $used_root_namespace = 1;
} else {
    foreach my $file (@to_process) {
        # get rid of trailing slash.
        $file =~ s/\/$//g;

        if (-e $file) {
            # this exists, operate on it.
            patt_this($file);
            $patted_something = 1;
        } else {
            warn "[warn]: $file does not exist, so we can't PATT that.\n";
        }
    
        if ($file eq "." || $file eq "./") {
            $used_root_namespace = 1;
            last;
        }
    }
}

unless ($used_root_namespace) {
    generate_dir_index_file(undef, { files => [@to_process] }) unless -e "index.html";
    upload_file("$this_patt_at/", "index.html");
}

# parallel upload all the files.
upload_files();

foreach my $file (@{$files_created}) {
    print "[verbose]: cleaning up created file $file\n" if $opts->{v};
    unlink($file);
}

if ($patted_something) {
    print "\nPATT successful (unless otherwise noted above)!\n\n";
    print "Your content is available at the address that follows.  Remember do\n";
    print "not use URL-shortening services, as they weaken the complexity of\n";
    print "the PATT namespace significantly.  We like our haystacks LARGE.\n\n";
    if ($opts->{n}) {
        print "$this_patt_at\n\n";
    } else {
        print "$this_patt_at/\n\n";
    }
    printf ("%-38s: %s\n", "This PATT will be read-only until", scalar(localtime(now_plus_denom($opts->{p}))));
    printf ("%-38s: %s\n", "This PATT will be expire at", scalar(localtime(now_plus_denom($opts->{e}))));
    print "\n";
}

sub patt_this {
    my ($file, %extras) = @_;

    # skip things we ignore...
    my $ignored;
    foreach my $ignore (@{$opts->{i}}) {
        my @fc = split(/\//, $file);
        if ($fc[$#fc] =~ /^$ignore/) {
            $ignored = 1;
        }
    }

    next if $ignored;

    if (-d $file) {
        if ($opts->{r}) {
            # add the relative path here?
            if ($extras{relative_path}) {
                my @fc = split(/\//, $file);
                $extras{relative_path} .= "/$fc[$#fc]";
            } elsif ($file =~ /^(?:\/|\.\.\/)/) {
                my @fc = split(/\//, $file);
                $extras{relative_path} = "$fc[$#fc]";
            }

            # this should get the subdirectories right :)
            if ($file eq ".") {
                unless (-e "index.html") {
                    generate_dir_index_file($file, { is_subdirectory => 0 });
                }
            } else {
                unless (-e "$file/index.html") {
                    generate_dir_index_file($file, { is_subdirectory => 1 });
                }
            }

            my $dh;
            opendir($dh, $file) or die "Can't opendir $dir\n";
            while (my $subfile = readdir($dh)) {
                # skip things we ignore...
                my $ignored;
                foreach my $ignore (@{$opts->{i}}) {
                    if ($subfile =~ /^$ignore/) {
                        $ignored = 1;
                    }
                }
                next if $ignored;

                # not the dots or the dot dots
                next if $subfile eq ".";
                next if $subfile eq "..";

                if (-d "$file/$subfile") {
                    # recurse!
                    if ($file eq ".") {
                        patt_this("$subfile", %extras);
                    } else {
                        patt_this("$file/$subfile", %extras);
                    }
                } else {
                    if ($subfile eq "index.html") {
                        if ($file eq ".") {
                            upload_file("$this_patt_at/", "index.html");
                        } elsif ($extras{relative_path}) {
                            upload_file("$this_patt_at/$extras{relative_path}/", "$file/index.html");
                        } else {
                            upload_file("$this_patt_at/$file/", "$file/index.html");
                        }
                    } else {
                        if ($file eq ".") {
                            upload_file("$this_patt_at/$subfile", "$subfile");
                        } elsif ($extras{relative_path}) {
                            upload_file("$this_patt_at/$extras{relative_path}/$subfile", "$file/$subfile");
                        } else {
                            upload_file("$this_patt_at/$file/$subfile", "$file/$subfile");
                        }
                    }
                }
            }
            closedir($dh);
        } else {
            warn "[warn]: $file is a directory, if you want to recurse into directories use -r\n";
        }
    } else {
        # file is a file!
        if ($opts->{n}) {
            upload_file("$this_patt_at", $file);
        } else {
            if ($file =~ /^(?:\/|\.\.\/)/) {
                my @fc = split(/\//, $file); 
                upload_file("$this_patt_at/$fc[$#fc]", $file);
            } elsif ($extras{relative_path}) {
                my @fc = split(/\//, $file); 
                upload_file("$this_patt_at/$extras{relative_path}/$fc[$#fc]", $file);
            } else {
                upload_file("$this_patt_at/$file", $file);
            }
        }
    }
}

sub generate_dir_index_file {
    my ($dir, $extra) = @_;

    # initialize indexed
    my $indexed = {};
    if ($dir eq "." || !$dir) {
        $indexed->{__directory__} = "<em>this directory</em>";
    } else {
        $indexed->{__directory__} = "$dir/";
    }
    if ($dir) {
        my $dh;
        opendir($dh, $dir) or die "Can't opendir $dir\n";

        while (my $file = readdir($dh)) {
            # skip things we ignore...
            my $ignored;
            foreach my $ignore (@{$opts->{i}}) {
                my @fc = split(/\//, $file);
                if ($fc[$#fc] =~ /^$ignore/) {
                    $ignored = 1;
                }
            }
            next if $ignored;

            next if $file eq ".";
            # if we're not a subdirectory, don't put a link back to the parent
            unless ($extra->{is_subdirectory}) {
                next if $file eq "..";
            }

            # gotta stat!
            my @stat = stat "$dir/$file";

            $indexed->{$file}->{name} = $file;

            # here's the modified time..
            my @mtime = localtime($stat[9]);
            $indexed->{$file}->{mtime} = sprintf('%02d/%02d/%d %02d:%02d:%02d', $mtime[4] + 1, $mtime[3], $mtime[5] + 1900, $mtime[2], $mtime[1], $mtime[0]);

            # compute size!
            if (-d "$dir/$file") {
                $indexed->{$file}->{directory} = 1;
                $indexed->{$file}->{rowclass} = "folder-icon";
                $indexed->{$file}->{size} = "--";
            } else {
                $indexed->{$file}->{size} = pretty_size($stat[7]);

                # get the mimetype of the file and figure out what our rowclass is
                my $mimetype = mimetype("$dir/$file");
                if ($mimetype =~ /image/) {
                    $indexed->{$file}->{rowclass} = "image-icon";
                } else {
                    $indexed->{$file}->{rowclass} = "document-icon";
                }
            }
        }
        closedir($dh);   
    } else {
        foreach my $file (@{$extra->{files}}) {
            # gotta stat!
            my @stat = stat "$file";

            my $name;
            if ($file =~ /^(?:\/|\.\.\/)/) {
                my @fc = split(/\//, $file);
                if (!$fc[$#fc]) {
                    $name = $fc[$#fc - 1] . "/";
                } else {
                    $name = $fc[$#fc];
                }
            } else {
                $name = $file;
            }

            $indexed->{$name}->{name} = $name;

            # here's the modified time..
            my @mtime = localtime($stat[9]);
            $indexed->{$name}->{mtime} = sprintf('%02d/%02d/%d %02d:%02d:%02d', $mtime[4] + 1, $mtime[3], $mtime[5] + 1900, $mtime[2], $mtime[1], $mtime[0]);

            # compute size!
            if (-d "$file") {
                $indexed->{$name}->{directory} = 1;
                $indexed->{$name}->{rowclass} = "folder-icon";
                $indexed->{$name}->{size} = "--";
            } else {
                $indexed->{$name}->{size} = pretty_size($stat[7]);
                # get the mimetype of the file and figure out what our rowclass is
                my $mimetype = mimetype("$file");
                if ($mimetype =~ /image/) {
                    $indexed->{$name}->{rowclass} = "image-icon";
                } else {
                    $indexed->{$name}->{rowclass} = "document-icon";
                }
            }
        }
    }

    my $mt = Mojo::Template->new;
    if ($dir) {
        push(@{$files_created}, "$dir/index.html");
        my $rendered = $mt->render($template_string, $indexed);
        open(OUTFILE, '>', "$dir/index.html");
        print OUTFILE $rendered;
        close(OUTFILE);
    } else {
        push(@{$files_created}, "index.html");
        my $rendered = $mt->render($template_string, $indexed);
        open(OUTFILE, '>', "index.html");
        print OUTFILE $rendered;
        close(OUTFILE);
    }

}

sub pretty_size {
    my ($bytes, $precision) = @_;
    my @units = ('bytes','kB','MB','GB','TB','PB','EB','ZB','YB');
    my $unit = 0;
    $precision = $precision ? 10**$precision : 1;

    while ($bytes > 1024) {
        $bytes /= 1024;
        $unit++;
    }

    if ($units[$unit]) {
        return int(($bytes * $precision) / $precision) . " $units[$unit]";
    } else {
        return int($bytes);
    }
}

# non blocking setup
sub upload_file {
    $upload_list->{$_[0]} = $_[1];
}

# non blocking uploader.. saves a LOT of time.
sub upload_files {
    my $ua = Mojo::UserAgent->new(
        connect_timeout => 50,
        inactivity_timeout => 50,
        request_timeout => 50,
        max_connections => 500,
    );

    # set this twice
    Mojo::IOLoop->max_connections(500);
    my $delay = Mojo::IOLoop->delay;

    while(my ($where, $file) = each %$upload_list) {
        $i++;

        # donno what this is gonna do...
        $delay->begin;

        Mojo::IOLoop->timer(0.05 * $i, sub {
            my $mime_type;
            if ($file =~ /index\.html$/) {
                $mime_type = mimetype($file);
            } else {
                my ($ext) = $file =~ /(\.\w+)$/;
                if ($opts->{m}->{$ext}) {
                    $mime_type = $opts->{m}->{$ext};
                } else {
                    $mime_type = mimetype($file);
                }
            }

            $ua->post_form($where =>
                {
                    protect_for => $opts->{p},
                    expires_in => $opts->{e},
                    op => 'put',
                    f => {
                        file => $file,
                        'Content-Type' => $mime_type,
                    },
                } => sub {
                    my ($ua, $tx) = @_;
                    if ($tx->res->code eq "302") {
                        print "[verbose]: successfully PATTed $file ($mime_type)\n" if $opts->{v};
                    } else {
                        warn "[error]: there was a problem PATTing $file ($mime_type)\n";
                    }
                    $delay->end;
                }
            );
        });
    }

    $delay->wait;
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

sub new_uuid {
    my $ud = Data::UUID->new;
    return $ud->create_str;
}

__DATA__
<!doctype html>
<html>


    <head>
        % my ($indexed) = (@_);
        <meta charset="utf-8"/>
        <title> patt_that.pl - directory index of <%= $indexed->{__directory__} %> </title>
        <link rel="stylesheet" media="all" href=""/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <!-- Adding "maximum-scale=1" fixes the Mobile Safari auto-zoom bug: http://filamentgroup.com/examples/iosScaleBug/ -->
      <style>
      /*    Less Framework 4
        http://lessframework.com
        by Joni Korpi
        License: http://opensource.org/licenses/mit-license.php */


    /*  Resets
        ------  */

    html, body, div, span, object, iframe, h1, h2, h3, h4, h5, h6, 
    p, blockquote, pre, a, abbr, address, cite, code, del, dfn, em, 
    img, ins, kbd, q, samp, small, strong, sub, sup, var, b, i, hr, 
    dl, dt, dd, ol, ul, li, fieldset, form, label, legend, 
    table, caption, tbody, tfoot, thead, tr, th, td,
    article, aside, canvas, details, figure, figcaption, hgroup, 
    menu, footer, header, nav, section, summary, time, mark, audio, video {
        margin: 0;
        padding: 0;
        border: 0;
    }

    article, aside, canvas, figure, figure img, figcaption, hgroup,
    footer, header, nav, section, audio, video {
        display: block;
    }

    a img {border: 0;}



    /*  Typography presets
        ------------------  */

    .gigantic {
        font-size: 110px;
        line-height: 120px;
        letter-spacing: -2px;
    }

    .huge, h1 {
        font-size: 68px;
        line-height: 72px;
        letter-spacing: -1px;
    }

    .large, h2 {
        font-size: 42px;
        line-height: 48px;
    }

    .bigger, h3 {
        font-size: 26px;
        line-height: 36px;
    }

    .big, h4 {
        font-size: 22px;
        line-height: 30px;
    }

    body {
        font: 16px/24px Monoco, Courier, Courier new, serif;
    }

    .small, small {
        font-size: 13px;
        line-height: 18px;
    }

    /* Selection colours (easy to forget) */

    ::selection         {background: rgb(255,255,158);}
    ::-moz-selection    {background: rgb(255,255,158);}
    img::selection      {background: transparent;}
    img::-moz-selection {background: transparent;}
    body {-webkit-tap-highlight-color: rgb(255,255,158);}



    /*      Default Layout: 992px. 
            Gutters: 24px.
            Outer margins: 48px.
            Leftover space for scrollbars @1024px: 32px.
    -------------------------------------------------------------------------------
    cols    1     2      3      4      5      6      7      8      9      10
    px      68    160    252    344    436    528    620    712    804    896    */

    body {
        width: 896px;
        padding: 72px 48px 84px;
        background: #fff;
        color: rgb(60,60,60);
        -webkit-text-size-adjust: 100%; /* Stops Mobile Safari from auto-adjusting font-sizes */
    }



    /*      Tablet Layout: 768px.
            Gutters: 24px.
            Outer margins: 28px.
            Inherits styles from: Default Layout.
    -----------------------------------------------------------------
    cols    1     2      3      4      5      6      7      8
    px      68    160    252    344    436    528    620    712    */

    @media only screen and (min-width: 768px) and (max-width: 991px) {

        body {
            width: 712px;
            padding: 48px 28px 60px;
        }
    }



    /*      Mobile Layout: 320px.
            Gutters: 24px.
            Outer margins: 34px.
            Inherits styles from: Default Layout.
    ---------------------------------------------
    cols    1     2      3
    px      68    160    252    */

    @media only screen and (max-width: 767px) {

        body {
            width: 252px;
            padding: 48px 34px 60px;
        }

    }



    /*      Wide Mobile Layout: 480px.
            Gutters: 24px.
            Outer margins: 22px.
            Inherits styles from: Default Layout, Mobile Layout.
    ------------------------------------------------------------
    cols    1     2      3      4      5
    px      68    160    252    344    436    */

    @media only screen and (min-width: 480px) and (max-width: 767px) {

        body {
            width: 436px;
            padding: 36px 22px 48px;
        }

    }


    /*  Retina media query.
        Overrides styles for devices with a 
        device-pixel-ratio of 2+, such as iPhone 4.
    -----------------------------------------------    */

    @media 
        only screen and (-webkit-min-device-pixel-ratio: 2),
        only screen and (min-device-pixel-ratio: 2) {

        body {

        }

    }

    td.document-icon {
        margin:0 0 .1em;
        background:url(data:image/gif;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABpklEQVQ4jYWTsXLTQBCGv907M2Nkx0IqJMzIjRt3pHFBx/AQPIDfgZaUFLwDNQ0FD4DfxMMMaYInieWMhJMw1lJYBgssss3d/jP77f47d2JmiIgCrwDl4aiAuZlVAL4WPXCyXuefHqpO06fvgyCIkyS5Xy6Xn/cdFeirCkVZUpQFZVFQlAVFUVLWuYhydvb2zXz+5eN2uz0BOv4A3lFx3KxvyPOcMAz/OQeDAT/KEhGlqqo+4A4BiApxFBFHTzARojhCzIijCMMQddze3aMimJk/3MHOhypX19fkeQ5AGIYAjQm63S6if3bdADjnSNOENE12ggHC79w5x2azQVXaARcX3xve95MMnw1x6uj3ezjnjgNElGyUMcoyEBiNMrDdIAiIKqKKagsA4PzbecP3/n56+rxuIoi0WAAYj8dgtXkMExATTGy36IPio4DFYnH0HUyn090Eqv8HTCaTv6VGqLQDforIO+/9i9ls9vJYca/XI8uyhib1b3wERMAwCILXVVWlwOMjjK2I3Dnnrrz3X1er1Qc5+M4e6AJxDeu0uDBgA1wCl78AaDycWBqEpLgAAAAASUVORK5CYII=) 
         left no-repeat; )
        min-height: 14px;
        text-indent:1.5em;
    }

    td.image-icon {
        margin:0 0 .1em;
        background:url(data:image/gif;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABiUlEQVQ4jaWTvW4TQRSFvxnPetkN6wQrgMCCEnpQ6giEBBIlPAovQEfJi1AiRAEdFEhIlDRIoAiFv9ibRJb35965FLtJYxcEH2m6Od89MzrXmRnryK/lBlwPufsfsAi8DUAARmb24kyTnXsEhNBPLmKMPHjyijQvwHXRYv8/rnOAGdLUvHx2D6AAfOiBiWpk5+EuWZ6xlXvCwFHVStVYZ3YO70FFUVWAhD4+AKrC45tCvjlAHLQO2jhgUUMSwHuYHSrz4wrV5PQpp4BWhBsjY6MAM2NWg2Jk255vfxa8//CTN69/oPOa+89vLwNUhEULx7/h3aeSz3slR/OK7SuBj19L9r4cYCKY1IjIMkBEGYQNflVQbqUM0zHjaDiM3cklhnc8zntUFJF2VQKlPPxONjrPrWuegwXM5kqDo1XYn9ZUtdJUNXr9wgpAVIoshzaSEbmcAingDAy4mHTX3TlU4xKgnUyuPgVGK1uzrCOgha4jQ2Dcn+E/AhpgCkxPduGkkWdRBMStu85/AdFjrAwP+6TsAAAAAElFTkSuQmCC) 
         left no-repeat; )
        min-height: 14px;
        text-indent:1.5em;
    }
    
    td.folder-icon {
        margin:0 0 .1em;
        background:url(data:image/gif;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAB40lEQVQ4jaWTvW4TQRSFv9mZiZf8rI1kSKrkAQDJjUUiS7RBooQaiRegJH6cIFp6bFlIhMqN6VAqiqTCxEQ22F7vzuxeil3jFIkUKVc65b3znaMzSkS4ywR32gYMgCrm8f7+waNqNap7770xRo/H49/9fr8jIuMbL5QWTK1WO4jnsUie/1en0/neaDReAlpEuE6qtPG82+2+bTabh957ALTWRFHE6enp+fvj489ASoEbWGuzXq/3YTAY9A1Qabfbr1ut1uHo4hdXI43jOTs727tHR+/egAIFkgtbUYTW+v5gMPhmgEqaJFsnJ1+YTCbXmFSopV1AAVG1ymIx3wRCA2jnXfDw6QuerIPVYAIQAZ+DywolDlIPiYfYg+t80oAxy9PDqTBOFRshhBZygVkKsximCVz+hT9zmMwhWQhlfcQU+zlGg1bFy5kvcLXAmoZ1A9k90AFoA3EIPyVf9QARZjEkpsDUpQWXwcLBIoVpXCoBn4KUcRcEeU4thCAAo8GUqWUBbGpwFqoVWGzA3IHP4DJfEShjrf4xFARB6xWBzyHLCqo4hSQtaBAw1mpAKaD2oF5/tbe3+8w5Z26s7JWx1vqzs/OvF6PRRwWEwDZQB9Zuc4CilSNguKyyLe3c9nfmgAfcP2859yzknw/FAAAAAElFTkSuQmCC) 
         left no-repeat; )
        min-height: 14px;
        text-indent:1.5em;
    }
    
    table {
        width: 80%;
    }
    
    tr {
        width: 100%;
    }
    
    td {
        padding: 2px;
    }
    
    tr.header {
        font-weight: bold;
        text-align: left;
    }
    tr.header > td {
        border-bottom: 2px black solid;
        padding: 0;
    }
    
    </style>
    </head>
    
    <body lang="en">
        <h3>patt_that.pl - listing of <%= $indexed->{__directory__} %></h3>
        <br/>
        <table class="file-list">
            <tr class="header">
                <td>File / Directory Name</td>
                <td>Size</td>
                <td>Last Mod</td>
            </tr>
            % foreach my $file (sort { $a cmp $b } keys %$indexed) {
            % if ($file ne "__directory__" && $indexed->{$file}->{directory}) {
            <tr>
                <td class="<%= $indexed->{$file}->{rowclass} %>"><a href="<%= $file %>/"><%= $file %>/</a></td>
                <td>--</td>
                <td><%= $indexed->{$file}->{mtime} %></td>
            </tr>
            % }
            % }
            % foreach my $file (sort { $a cmp $b } keys %$indexed) {
            % unless ($file eq "__directory__" || $indexed->{$file}->{directory}) {
            <tr>
                <td class="<%= $indexed->{$file}->{rowclass} %>"><a href="<%= $file %>"><%= $file %></a></td>
                <td><%= $indexed->{$file}->{size} %></td>
                <td><%= $indexed->{$file}->{mtime} %></td>
            </tr>
            % }
            % }
        </table>
    </body>
</html>
