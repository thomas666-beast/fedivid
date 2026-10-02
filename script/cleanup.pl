#!/usr/bin/env perl
use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid;
use Mojo::File qw(path);
use File::Find ();
use File::Path qw(remove_tree);

my $apply = grep { $_ eq '--apply' } @ARGV;

my $app = FediVid->new;
my $db  = $app->pg->db;

my $base_dir = $app->config('upload_dir') // 'uploads';

say $apply ? "=== APPLY MODE ===" : "=== DRY RUN (pass --apply to delete) ===";

# --- 1. Completed deliveries older than 7 days ---
{
    my $count = $db->query(
        "SELECT COUNT(*) AS n FROM deliveries
          WHERE completed_at IS NOT NULL
            AND completed_at < NOW() - INTERVAL '7 days'"
    )->hash->{n};
    say "Completed deliveries older than 7 days: $count";
    if ($apply && $count) {
        $db->query(
            "DELETE FROM deliveries
              WHERE completed_at IS NOT NULL
                AND completed_at < NOW() - INTERVAL '7 days'"
        );
    }
}

# --- 2. Expired rate-limit windows ---
{
    my $count = $db->query(
        "SELECT COUNT(*) AS n FROM rate_limits
          WHERE window_start < NOW() - INTERVAL '1 hour'"
    )->hash->{n};
    say "Rate-limit rows older than 1 hour: $count";
    if ($apply && $count) {
        $db->query(
            "DELETE FROM rate_limits
              WHERE window_start < NOW() - INTERVAL '1 hour'"
        );
    }
}

# --- 3. Seen notifications older than 30 days ---
{
    my $count = $db->query(
        "SELECT COUNT(*) AS n FROM notifications
          WHERE seen_at IS NOT NULL
            AND seen_at < NOW() - INTERVAL '30 days'"
    )->hash->{n};
    say "Seen notifications older than 30 days: $count";
    if ($apply && $count) {
        $db->query(
            "DELETE FROM notifications
              WHERE seen_at IS NOT NULL
                AND seen_at < NOW() - INTERVAL '30 days'"
        );
    }
}

# --- 4. Remote actors not refreshed in 30 days ---
{
    my $count = $db->query(
        "SELECT COUNT(*) AS n FROM remote_actors
          WHERE fetched_at < NOW() - INTERVAL '30 days'"
    )->hash->{n};
    say "Remote actors older than 30 days: $count";
    if ($apply && $count) {
        $db->query(
            "DELETE FROM remote_actors
              WHERE fetched_at < NOW() - INTERVAL '30 days'"
        );
    }
}

# --- 5. Orphaned upload files ---
{
    unless (-d $base_dir) {
        say "Upload dir does not exist: skipping file cleanup";
    } else {
        # Known video files
        my $known_video = $db->query(
            'SELECT file_path FROM videos WHERE file_path IS NOT NULL'
        )->arrays->map(sub { $_->[0] })->to_array;

        # Known avatar files
        my $known_avatar = $db->query(
            'SELECT avatar_path FROM users WHERE avatar_path IS NOT NULL'
        )->arrays->map(sub { $_->[0] })->to_array;

        my %known = map { $_ => 1 } (@$known_video, @$known_avatar);

        my @orphans;
        File::Find::find({
            no_chdir => 1,
            wanted   => sub {
                my $path = $File::Find::name;
                return unless -f $path;
                # Skip HLS segments — those are handled in step 6
                return if $path =~ m{/hls/};
                push @orphans, $path unless $known{$path};
            },
        }, $base_dir);

        say "Orphaned upload files: " . scalar(@orphans);
        if ($apply) {
            for my $f (@orphans) {
                unlink $f;
                say "  deleted: $f";
            }
        } else {
            say "  would delete: $_" for @orphans;
        }
    }
}

# --- 6. Orphaned HLS directories ---
{
    unless (-d $base_dir) {
        say "Upload dir does not exist: skipping HLS cleanup";
    } else {
        my $known = $db->query(
            "SELECT hls_dir FROM videos WHERE hls_dir IS NOT NULL"
        )->arrays->map(sub { $_->[0] })->to_array;
        my %known = map { $_ => 1 } @$known;

        # Walk to each uploads/<user>/hls/<videoid> directory
        my @hls_dirs;
        File::Find::find({
            no_chdir => 1,
            wanted   => sub {
                my $path = $File::Find::name;
                return unless -d $path;
                push @hls_dirs, $path if $path =~ m{/hls/\d+\z};
            },
        }, $base_dir);

        my @orphans;
        for my $d (@hls_dirs) {
            push @orphans, $d unless $known{$d};
        }

        say "Orphaned HLS directories: " . scalar(@orphans);
        if ($apply) {
            for my $d (@orphans) {
                remove_tree($d);
                say "  deleted: $d";
            }
        } else {
            say "  would delete: $_" for @orphans;
        }
    }
}

say $apply ? "Done." : "Done. Nothing was deleted.";
