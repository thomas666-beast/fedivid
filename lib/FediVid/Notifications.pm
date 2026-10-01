package FediVid::Notifications;
use Mojo::Base -strict, -signatures;

use Exporter 'import';
our @EXPORT_OK = qw(notify);

sub notify ($db, $username, $type, $actor, $object_id, $object_url, $video_id = undef) {
    return (0, 'no username') unless $username;
    return (0, 'no type')     unless $type;
    return (0, 'no actor')    unless $actor;

    # For 'create' notifications, dedupe: one per (username, actor, object).
    # Retried deliveries or backfilled activities shouldn't produce a
    # second notification for the same video.
    if ($type eq 'create' && defined $object_id) {
        my $existing = $db->query(
            'SELECT 1 FROM notifications
              WHERE username = ? AND type = ? AND actor = ? AND object_id = ?
              LIMIT 1',
            $username, $type, $actor, $object_id
        )->array;
        return (1, undef) if $existing;
    }

    $db->query(
        'INSERT INTO notifications
             (username, type, actor, object_id, object_url, video_id)
         VALUES (?, ?, ?, ?, ?, ?)',
        $username, $type, $actor, $object_id, $object_url, $video_id
    );

    return (1, undef);
}

1;
