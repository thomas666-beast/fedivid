package FediVid::Outbox;
use Mojo::Base -strict, -signatures;

use Exporter 'import';
our @EXPORT_OK = qw(fetch_recent_videos);

sub fetch_recent_videos ($ua, $actor_url, $limit = 20) {
    my $outbox_url = "$actor_url/outbox";

    my $tx = $ua->get($outbox_url, {
        Accept => 'application/activity+json',
    });

    my $code = $tx->res->code // 0;
    return [] unless $code == 200;

    my $col = $tx->res->json;
    return [] unless $col && ref $col eq 'HASH';

    # Collect activities from either the collection itself or its first page
    my @activities;

    if (ref $col->{orderedItems} eq 'ARRAY' && @{ $col->{orderedItems} }) {
        @activities = @{ $col->{orderedItems} };
    } else {
        my $first = $col->{first};
        $first = $first->{id} if ref $first eq 'HASH';
        return [] unless $first;

        my $page_tx = $ua->get($first, {
            Accept => 'application/activity+json',
        });
        return [] unless ($page_tx->res->code // 0) == 200;

        my $page = $page_tx->res->json;
        return [] unless $page && ref $page->{orderedItems} eq 'ARRAY';

        @activities = @{ $page->{orderedItems} };
    }

    my @videos;
    for my $item (@activities) {
        last if @videos >= $limit;
        next unless ref $item eq 'HASH';

        my $type = $item->{type} // '';
        next unless $type eq 'Create';

        my $obj = $item->{object};
        next unless ref $obj eq 'HASH';
        next unless ($obj->{type} // '') eq 'Video';

        push @videos, $item;
    }

    return \@videos;
}

1;
