package FediVid::Controller::Feed;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(decode_json);

sub instance ($c) {
    my $db   = $c->pg->db;
    my $base = $c->config('base_url');
    my $name = $c->config('instance_name') // 'FediVid';

    my $videos = $db->query(
        'SELECT id, username, title, description, activity_id,
                duration_seconds, transcode_status, published_at
           FROM videos
          WHERE transcode_status = ? 
          ORDER BY published_at DESC
          LIMIT 50',
        'ready'
    )->hashes;

    my @items;
    for my $v (@$videos) {
        push @items, {
            title       => $v->{title},
            link        => "$base/u/$v->{username}/v/$v->{id}",
            description => $v->{description} // '',
            author      => $v->{username},
            pubDate     => _rfc822($v->{published_at}),
            guid        => "$base/users/$v->{username}/videos/$v->{id}",
            enclosure   => "$base/remote-posters/$v->{id}.jpg",
            mediaType   => 'image/jpeg',
        };
    }

    _render_feed($c, {
        title       => $name,
        link        => $base,
        description => $c->config('instance_description') // '',
        items       => \@items,
    });
}

sub user ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;
    my $base     = $c->config('base_url');

    my $user = $db->query(
        'SELECT 1 FROM users WHERE username = ?', $username
    )->array;
    return $c->render(status => 404, text => 'Not found')
        unless $user;

    my $videos = $db->query(
        'SELECT id, username, title, description, activity_id,
                duration_seconds, transcode_status, published_at
           FROM videos
          WHERE username = ? AND transcode_status = ?
          ORDER BY published_at DESC
          LIMIT 50',
        $username, 'ready'
    )->hashes;

    my @items;
    for my $v (@$videos) {
        push @items, {
            title       => $v->{title},
            link        => "$base/u/$username/v/$v->{id}",
            description => $v->{description} // '',
            author      => $username,
            pubDate     => _rfc822($v->{published_at}),
            guid        => "$base/users/$username/videos/$v->{id}",
        };
    }

    _render_feed($c, {
        title       => "$username on " . ($c->config('instance_name') // 'FediVid'),
        link        => "$base/users/$username",
        description => "Latest videos from $username",
        items       => \@items,
    });
}

sub _render_feed ($c, $feed) {
    my $xml = <<"HEADER";
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
  <channel>
    <title>@{[ _esc($feed->{title}) ]}</title>
    <link>@{[ _esc($feed->{link}) ]}</link>
    <description>@{[ _esc($feed->{description}) ]}</description>
    <atom:link href="@{[ _esc($c->req->url->to_abs->to_string) ]}" rel="self" type="application/rss+xml"/>
    <language>en</language>
HEADER

    for my $item (@{ $feed->{items} }) {
        my $enclosure = '';
        if ($item->{enclosure}) {
            $enclosure = qq{    <enclosure url="@{[ _esc($item->{enclosure}) ]}" type="$item->{mediaType}" length="0"/>\n};
        }

        $xml .= <<"ITEM";
    <item>
      <title>@{[ _esc($item->{title}) ]}</title>
      <link>@{[ _esc($item->{link}) ]}</link>
      <description>@{[ _esc($item->{description}) ]}</description>
      <author>@{[ _esc($item->{author}) ]}</author>
      <pubDate>$item->{pubDate}</pubDate>
      <guid isPermaLink="false">@{[ _esc($item->{guid}) ]}</guid>
$enclosure    </item>
ITEM
    }

    $xml .= "  </channel>\n</rss>\n";

    $c->res->headers->content_type('application/rss+xml; charset=utf-8');
    $c->render(data => $xml);
}

sub _rfc822 ($ts) {
    return '' unless $ts;
    require Mojo::Date;
    my $epoch = eval { Mojo::Date->new($ts)->epoch } // time;
    my @t = gmtime($epoch);
    my @dow = qw(Sun Mon Tue Wed Thu Fri Sat);
    my @mon = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    return sprintf('%s, %02d %s %04d %02d:%02d:%02d GMT',
        $dow[$t[6]], $t[3], $mon[$t[4]], $t[5] + 1900,
        $t[2], $t[1], $t[0]);
}

sub _esc ($s) {
    return '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

1;
