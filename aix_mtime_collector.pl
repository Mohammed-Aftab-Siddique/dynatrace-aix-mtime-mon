#!/usr/bin/perl

use strict;
use warnings;
use Errno qw(ENOENT ENOTDIR);
use Fcntl qw(S_ISREG);
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);
use bytes;

my $host;
my $directories_file;
my $output_file;
my $output_directory;
my $max_batch_bytes = 900_000;
my $now;
my $help;

GetOptions(
    'host=s'        => \$host,
    'directories=s' => \$directories_file,
    'output=s'      => \$output_file,
    'output-directory=s' => \$output_directory,
    'max-batch-bytes=i'  => \$max_batch_bytes,
    'now=i'         => \$now,
    'help'          => \$help,
) or usage(1);

usage(0) if $help;

die "--host is required\n" unless defined $host && length $host;
die "--directories is required\n"
    unless defined $directories_file && length $directories_file;
die "specify exactly one of --output or --output-directory\n"
    unless ((defined $output_file && length $output_file) xor
            (defined $output_directory && length $output_directory));
die "--max-batch-bytes must be greater than zero\n" unless $max_batch_bytes > 0;
die "host must not contain a newline\n" if $host =~ /[\r\n]/;

$now = time() unless defined $now;

my @directories = read_directories($directories_file);
die "no directories configured in $directories_file\n" unless @directories;

my $payload;
my $payload_bytes = 0;
my $batch_count = 0;

if (defined $output_file) {
    open $payload, '>', $output_file
        or die "cannot create payload $output_file: $!\n";
    $batch_count = 1;
}

my $emit_metric = sub {
    my ($line) = @_;

    die "a single metric line exceeds the configured batch size\n"
        if defined $output_directory && length($line) > $max_batch_bytes;

    if (defined $output_directory &&
        (!defined $payload || $payload_bytes + length($line) > $max_batch_bytes)) {
        if (defined $payload) {
            close $payload or die "cannot close metric batch: $!\n";
        }

        $batch_count++;
        my $batch_path = sprintf('%s/payload.%04d.txt', $output_directory, $batch_count);
        open $payload, '>', $batch_path
            or die "cannot create metric batch $batch_path: $!\n";
        $payload_bytes = 0;
    }

    print {$payload} $line or die "cannot write metric payload: $!\n";
    $payload_bytes += length($line);
};

my $escaped_host = escape_dimension($host);
my $directory_count = 0;
my $file_count = 0;
my $metric_count = 0;
my $warning_count = 0;

for my $directory (@directories) {
    $directory_count++;

    my $directory_handle;
    unless (opendir $directory_handle, $directory) {
        warn "cannot open directory $directory: $!\n";
        $warning_count++;
        next;
    }

    my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir $directory_handle;
    closedir $directory_handle
        or warn "cannot close directory $directory: $!\n";

    my $files_in_directory = 0;

    for my $filename (@entries) {
        if ($filename =~ /[\r\n]/) {
            warn "skipping filename containing a newline in $directory\n";
            $warning_count++;
            next;
        }

        my $path = $directory eq '/' ? "/$filename" : "$directory/$filename";
        my @status = stat $path;

        unless (@status) {
            if ($! == ENOENT || $! == ENOTDIR) {
                warn "file disappeared before it could be inspected: $path\n";
            } else {
                warn "cannot stat file $path: $!\n";
            }
            $warning_count++;
            next;
        }

        next unless S_ISREG($status[2]);

        my $mtime_epoch = $status[9];
        my $age_seconds = $now - $mtime_epoch;
        my $mtime_ist = format_ist($mtime_epoch);

        unless (defined $mtime_ist) {
            warn "cannot format modification time for $path\n";
            $warning_count++;
            next;
        }

        my $escaped_directory = escape_dimension($directory);
        my $escaped_filename = escape_dimension($filename);
        my $escaped_mtime = escape_dimension($mtime_ist);

        $emit_metric->(
            qq{custom.file.age.seconds,host="$escaped_host",dir="$escaped_directory",filename="$escaped_filename" $age_seconds\n}
        );
        $emit_metric->(
            qq{custom.file.mtime.display,host="$escaped_host",dir="$escaped_directory",filename="$escaped_filename",mtime="$escaped_mtime" 1\n}
        );

        $files_in_directory++;
        $file_count++;
        $metric_count += 2;
    }

    my $escaped_directory = escape_dimension($directory);
    $emit_metric->(
        qq{custom.directory.file.count,host="$escaped_host",dir="$escaped_directory" $files_in_directory\n}
    );
    $metric_count++;
}

close $payload or die "cannot close metric payload: $!\n" if defined $payload;

print "directories=$directory_count files=$file_count metrics=$metric_count batches=$batch_count warnings=$warning_count\n";
exit($warning_count ? 2 : 0);

sub read_directories {
    my ($path) = @_;
    open my $handle, '<', $path or die "cannot read directory config $path: $!\n";

    my @result;
    my %seen;
    my $line_number = 0;

    while (my $line = <$handle>) {
        $line_number++;
        $line =~ s/[\r\n]+\z//;
        next if $line =~ /^\s*(?:#|\z)/;

        $line =~ s/^\s+//;
        $line =~ s/\s+\z//;

        die "$path:$line_number: directory must be an absolute path\n"
            unless $line =~ m{^/};

        $line =~ s{/+\z}{} unless $line eq '/';
        next if $seen{$line}++;
        push @result, $line;
    }

    close $handle or die "cannot close directory config $path: $!\n";
    return @result;
}

sub escape_dimension {
    my ($value) = @_;
    die "dimension value must not contain a newline\n" if $value =~ /[\r\n]/;
    $value =~ s/\\/\\\\/g;
    $value =~ s/"/\\"/g;
    return $value;
}

sub format_ist {
    my ($epoch_seconds) = @_;
    my $formatted = eval {
        strftime('%Y-%m-%dT%H:%M:%S+05:30', gmtime($epoch_seconds + 19_800));
    };
    return if $@ || !defined $formatted || !length $formatted;
    return $formatted;
}

sub usage {
    my ($exit_code) = @_;
    print <<'USAGE';
Usage: aix_mtime_collector.pl --host HOST --directories FILE
       (--output FILE | --output-directory DIR)
       [--max-batch-bytes BYTES] [--now EPOCH]

Collects metrics for regular files immediately inside each configured directory.
The optional --now argument is intended for deterministic testing.
USAGE
    exit $exit_code;
}
