#!/usr/bin/env perl
use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid;
use FediVid::WorkerHeartbeat qw(beat);
use Mojo::JSON qw(decode_json);
use FediVid::Delivery;

my $app = FediVid->new;
my $db  = $app->pg->db;

my $loop         = grep { $_ eq '--loop' } @ARGV;
my $verbose      = grep { $_ eq '--verbose' } @ARGV;
my $max_attempts = 5;

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

log_msg("delivery worker starting" . ($loop ? " (loop mode)" : ""));

beat($db, 'delivery', 0);

while (1) {
    my $row = $db->query(
        "SELECT id, username, inbox_url, activity, attempts
           FROM deliveries
          WHERE completed_at IS NULL
            AND scheduled_at <= NOW()
            AND attempts < ?
          ORDER BY scheduled_at, id
          LIMIT 1
          FOR UPDATE SKIP LOCKED",
        $max_attempts
    )->hash;

    if (!$row) {
        beat($db, 'delivery', 0);
        last unless $loop;
        sleep 3;
        next;
    }

    my $user = $db->query(
        'SELECT private_key_pem FROM users WHERE username = ?',
        $row->{username}
    )->hash;

    if (!$user || !$user->{private_key_pem}) {
        log_msg("delivery $row->{id}: no private key for $row->{username}, giving up");
        $db->query(
            "UPDATE deliveries SET completed_at = NOW(),
                                    last_error = 'no private key'
              WHERE id = ?",
            $row->{id}
        );
        beat($db, 'delivery', 1);
        next;
    }

    my $base   = $app->config('base_url');
    my $key_id = "$base/users/$row->{username}#main-key";

    my $activity = eval { decode_json($row->{activity}) };
    if (!$activity) {
        log_msg("delivery $row->{id}: invalid activity JSON, giving up");
        $db->query(
            "UPDATE deliveries SET completed_at = NOW(),
                                    last_error = 'invalid activity JSON'
              WHERE id = ?",
            $row->{id}
        );
        beat($db, 'delivery', 1);
        next;
    }

    my $attempt = $row->{attempts} + 1;
    log_msg("delivery $row->{id} to $row->{inbox_url} (attempt $attempt/$max_attempts)");
    debug_msg("activity id: " . ($activity->{id} // '?'));
    debug_msg("activity type: " . ($activity->{type} // '?'));
    debug_msg("signing with key: $key_id");

    my $started = time;
    my ($ok, $err) = FediVid::Delivery::deliver(
        $app->ua, $db, $row->{username}, $row->{inbox_url},
        $key_id, $user->{private_key_pem}, $activity,
    );
    my $elapsed = time - $started;

    if ($ok) {
        log_msg("delivery $row->{id} delivered (${elapsed}s)");
        $db->query(
            'UPDATE deliveries SET completed_at = NOW(), attempts = attempts + 1
              WHERE id = ?',
            $row->{id}
        );
        beat($db, 'delivery', 1);
        next;
    }

    my $delay_seconds = 30 * (2 ** $row->{attempts});
    $delay_seconds = 3600 if $delay_seconds > 3600;

    my $give_up = $attempt >= $max_attempts;

    log_msg("delivery $row->{id} FAILED (${elapsed}s): $err"
          . ($give_up ? " -- giving up after $max_attempts attempts"
                      : " -- retry in ${delay_seconds}s"));

    $db->query(
        "UPDATE deliveries
            SET attempts = attempts + 1,
                last_error = ?,
                scheduled_at = NOW() + make_interval(secs => ?),
                completed_at = CASE WHEN ? THEN NOW() ELSE completed_at END
          WHERE id = ?",
        $err,
        $delay_seconds,
        ($give_up ? 1 : 0),
        $row->{id}
    );

    beat($db, 'delivery', 1);
}

log_msg("delivery worker exiting");
