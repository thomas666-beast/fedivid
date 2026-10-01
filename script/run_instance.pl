#!/usr/bin/env perl
use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/../lib";

my $name = shift @ARGV or die "usage: $0 <instance-name>\n";

my $env_file = "$FindBin::Bin/../instances/$name.env";
die "env file not found: $env_file\n" unless -f $env_file;

# Load env file into %ENV
open my $fh, '<', $env_file or die "open $env_file: $!";
while (my $line = <$fh>) {
    chomp $line;
    next if $line =~ /^\s*#/ || $line =~ /^\s*$/;
    my ($key, $value) = split /\s*=\s*/, $line, 2;
    $ENV{$key} = $value;
}
close $fh;

# Now boot the app with that env
require FediVid;
my $app = FediVid->new;
$app->start;
