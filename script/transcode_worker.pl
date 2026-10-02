#!/usr/bin/env perl
use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid;
use FediVid::Transcoder qw(transcode);
use FediVid::WorkerHeartbeat qw(beat);
use Mojo::File qw(path);
use Mojo::JSON qw(decode_json);

my $app = FediVid->new;
my $db  = $app->pg->db;

my $base_dir = $app->config('upload_dir') // 'uploads';

my $loop    = grep { $_ eq '--loop' } @ARGV;
my $verbose = grep { $_ eq '--verbose' } @ARGV;

my $stuck_minutes = 30;   # processing rows older than this are recovered

sub log_msg {
    my ($msg) = @_;
    my @t = localtime;
    printf "[%04d-%02d-%02d %02d:%02d:%02d] %s\n",
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0], $msg;
}

sub debug_msg {
    my ($msg) = @_;
    return unless $verbose;
    log_msg("  [debug] $msg");
}

sub recover_stuck_rows {
    my $result = $db->query(
        "UPDATE videos
            SET transcode_status = 'pending',
                transcode_started_at = NULL
          WHERE transcode_status = 'processing'
            AND (transcode_started_at IS NULL
                 OR transcode_started_at < NOW() - make_interval(mins => ?))
          RETURNING id",
        $stuck_minutes
    )->arrays;
    my $n = @$result;
    log_msg("recovered $n stuck processing row(s)") if $n;
}

log_msg("transcode worker starting" . ($loop ? " (loop mode)" : ""));

# Recover stuck rows on startup
recover_stuck_rows();

# Register heartbeat immediately so admin sees us right away
beat($db, 'transcode', 0);

my $last_recover = time;

while (1) {
    # --- Claim a video inside a transaction ---
    my $row;
    {
        my $tx = $db->begin;
        $row = $db->query(
            "SELECT id, file_path, username
               FROM videos
              WHERE transcode_status = 'pending'
              ORDER BY id
              LIMIT 1
              FOR UPDATE SKIP LOCKED"
        )->hash;

        if ($row) {
            $db->query(
                "UPDATE videos
                    SET transcode_status = 'processing',
                        transcode_started_at = NOW()
                  WHERE id = ?",
                $row->{id}
            );
        }
        $tx->commit;
    }

    if (!$row) {
        beat($db, 'transcode', 0);

        # Periodically recover stuck rows (every 5 minutes)
        if (time - $last_recover > 300) {
            recover_stuck_rows();
            $last_recover = time;
        }

        last unless $loop;
        sleep 5;
        next;
    }

    my $hls_dir = path($base_dir, $row->{username}, 'hls', $row->{id})->to_string;

    log_msg("transcoding video $row->{id} (user=$row->{username}) -> $hls_dir");
    debug_msg("input: $row->{file_path}");

    my $started = time;
    my ($master, $err) = transcode($row->{file_path}, $hls_dir);
    my $elapsed = time - $started;

    if (!$master) {
        log_msg("FAILED (${elapsed}s): $err");
        $db->query(
            "UPDATE videos SET transcode_status = 'failed' WHERE id = ?",
            $row->{id}
        );
        beat($db, 'transcode', 1);
        next;
    }

    log_msg("done (${elapsed}s): $master");
    debug_msg("master playlist: $master");
    debug_msg("poster: $hls_dir/poster.jpg");

    $db->query(
        "UPDATE videos SET transcode_status = 'ready', hls_dir = ? WHERE id = ?",
        $hls_dir, $row->{id}
    );

    beat($db, 'transcode', 1);

    # --- Deliver the Create activity to followers ---
    if ($ENV{FEDIVID_DISABLE_DELIVERY}) {
        debug_msg("delivery disabled by env");
        next;
    }

    my $user = $db->query(
        'SELECT private_key_pem FROM users WHERE username = ?', $row->{username}
    )->hash;
    if (!$user || !$user->{private_key_pem}) {
        debug_msg("no private key for $row->{username}, skipping delivery");
        next;
    }

    my $activity_row = $db->query(
        "SELECT activity FROM outbox_activities
          WHERE username = ? AND activity::text LIKE ?
          ORDER BY id DESC LIMIT 1",
        $row->{username}, "%/videos/%"
    )->hash;
    if (!$activity_row) {
        debug_msg("no matching outbox activity");
        next;
    }

    my $activity = decode_json($activity_row->{activity});
    debug_msg("activity id: " . ($activity->{id} // '?'));

    my $base   = $app->config('base_url');
    my $key_id = "$base/users/$row->{username}#main-key";

    my $followers = $db->query(
        'SELECT remote_inbox FROM followers
          WHERE local_user = ? AND accepted = TRUE AND remote_inbox IS NOT NULL',
        $row->{username}
    )->arrays;

    debug_msg("queuing deliveries to " . scalar(@$followers) . " followers");

    require FediVid::DeliveryQueue;
    my $count = 0;
    for my $f (@$followers) {
        my ($inbox) = @$f;
        FediVid::DeliveryQueue::enqueue(
            $db, $row->{username}, $inbox, $activity
        );
        $count++;
        debug_msg("  queued -> $inbox");
    }

    log_msg("queued $count delivery(ies) for video $row->{id}");
}

log_msg("transcode worker exiting");
