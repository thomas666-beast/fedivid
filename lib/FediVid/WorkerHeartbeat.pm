package FediVid::WorkerHeartbeat;
use Mojo::Base -strict, -signatures;

use Exporter 'import';
our @EXPORT_OK = qw(beat);

sub beat ($db, $name, $increment = 0) {
    $db->query(
        'INSERT INTO worker_heartbeats (name, last_seen, processed)
              VALUES (?, NOW(), ?)
         ON CONFLICT (name) DO UPDATE
             SET last_seen = NOW(),
                 processed = worker_heartbeats.processed + ?',
        $name, $increment, $increment
    );
}

1;
