package FediVid::Delivery;
use Mojo::Base -strict, -signatures;
use Mojo::JSON qw(encode_json);
use FediVid::Signature qw(sign_request);

sub deliver ($ua, $db, $username, $inbox_url, $key_id, $private_pem, $activity) {
    return (0, 'no inbox url') unless $inbox_url;

    my $body = encode_json($activity);

    my $tx = $ua->build_tx(POST => $inbox_url);
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body($body);
    sign_request($tx->req, $key_id, $private_pem);

    $ua->start($tx);

    my $res = $tx->res;
    return (0, 'no response from remote') unless $res;

    my $code = $res->code // 0;
    my $ok = $code >= 200 && $code < 300;

    # Record the outbound activity regardless of delivery outcome.
    if ($activity->{id}) {
        $db->query(
            'INSERT INTO outbox_activities (username, activity, activity_id)
                  VALUES (?, ?, ?)
             ON CONFLICT (activity_id) DO NOTHING',
            $username, $body, $activity->{id}
        );
    }

    return $ok ? (1, undef) : (0, "remote returned $code");
}

1;
