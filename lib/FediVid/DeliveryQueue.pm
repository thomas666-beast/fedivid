package FediVid::DeliveryQueue;
use Mojo::Base -strict, -signatures;
use Mojo::JSON qw(encode_json decode_json);

use Exporter 'import';
our @EXPORT_OK = qw(enqueue);

sub enqueue ($db, $username, $inbox_url, $activity) {
    return (0, 'no inbox url') unless $inbox_url;
    return (0, 'activity has no id') unless $activity->{id};

    $db->query(
        'INSERT INTO deliveries (username, inbox_url, activity, activity_id)
              VALUES (?, ?, ?, ?)',
        $username, $inbox_url, encode_json($activity), $activity->{id}
    );

    # Also record in the outbox so the user's own activities are visible.
    $db->query(
        'INSERT INTO outbox_activities (username, activity, activity_id)
              VALUES (?, ?, ?)
         ON CONFLICT (activity_id) DO NOTHING',
        $username, encode_json($activity), $activity->{id}
    );

    return (1, undef);
}

1;
