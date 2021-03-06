# This is free and unencumbered software released into the public domain.

#
#  59_Buienradar.pm
#       2018 lubeda
#       2019 ff. Christoph Morrison, <fhem@christoph-jeschke.de>

# Anyone is free to copy, modify, publish, use, compile, sell, or
# distribute this software, either in source code form or as a compiled
# binary, for any purpose, commercial or non-commercial, and by any
# means.

# In jurisdictions that recognize copyright laws, the author or authors
# of this software dedicate any and all copyright interest in the
# software to the public domain. We make this dedication for the benefit
# of the public at large and to the detriment of our heirs and
# successors. We intend this dedication to be an overt act of
# relinquishment in perpetuity of all present and future rights to this
# software under copyright law.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.

#  For more information, please refer to <http://unlicense.org/>

# See also https://www.buienradar.nl/overbuienradar/gratis-weerdata


package FHEM::Buienradar;

use strict;
use warnings;
use HttpUtils;
use JSON;
use List::Util;
use Time::Seconds;
use POSIX;
use Data::Dumper;
use English;
use Storable;
use GPUtils qw(GP_Import GP_Export);
use experimental qw( switch );

our $device;
our $version = '2.3.2';
our $default_interval = ONE_MINUTE * 2;
our @errors;

our %Translations = (
    'GChart' => {
        'hAxis' => {
            'de'    =>  'Uhrzeit',
            'en'    =>  'Time',
        },
        'vAxis' => {
            'de'    => 'mm/h',
            'en'    => 'mm/h',
        },
        'title' => {
            'de'    =>  'Niederschlagsvorhersage für %s, %s',
            'en'    =>  'Precipitation forecast for %s, %s',
        },
        'legend' => {
            'de'    => 'Niederschlag',
            'en'    => 'Precipitation',
        },
    }
);

our %severity_conditions = (
    15.00   =>  'tropical',
    10.00   =>  'rainstorm',
    5.00    =>  'heavy',
    2.00    =>  'mediumheavy',
    1.50    =>  'medium',
    1.00    =>  'lightmedium',
    0.50    =>  'light',
    0.25    =>  'drizzle',
    0       =>  'none',
);

GP_Export(
    qw(
        Initialize
    )
);

# try to use JSON::MaybeXS wrapper
#   for chance of better performance + open code
eval {
    require JSON::MaybeXS;
    import JSON::MaybeXS qw( decode_json encode_json );
    1;
};

if ($@) {
    $@ = undef;

    # try to use JSON wrapper
    #   for chance of better performance
    eval {

        # JSON preference order
        local $ENV{PERL_JSON_BACKEND} =
            'Cpanel::JSON::XS,JSON::XS,JSON::PP,JSON::backportPP'
            unless ( defined( $ENV{PERL_JSON_BACKEND} ) );

        require JSON;
        import JSON qw( decode_json encode_json );
        1;
    };

    if ($@) {
        $@ = undef;

        # In rare cases, Cpanel::JSON::XS may
        #   be installed but JSON|JSON::MaybeXS not ...
        eval {
            require Cpanel::JSON::XS;
            import Cpanel::JSON::XS qw(decode_json encode_json);
            1;
        };

        if ($@) {
            $@ = undef;

            # In rare cases, JSON::XS may
            #   be installed but JSON not ...
            eval {
                require JSON::XS;
                import JSON::XS qw(decode_json encode_json);
                1;
            };

            if ($@) {
                $@ = undef;

                # Fallback to built-in JSON which SHOULD
                #   be available since 5.014 ...
                eval {
                    require JSON::PP;
                    import JSON::PP qw(decode_json encode_json);
                    1;
                };

                if ($@) {
                    $@ = undef;

                    # Fallback to JSON::backportPP in really rare cases
                    require JSON::backportPP;
                    import JSON::backportPP qw(decode_json encode_json);
                    1;
                }
            }
        }
    }
}

#####################################
sub Initialize {

    my ($hash) = @_;

    $hash->{DefFn}       = "FHEM::Buienradar::Define";
    $hash->{UndefFn}     = "FHEM::Buienradar::Undefine";
    $hash->{GetFn}       = "FHEM::Buienradar::Get";
    $hash->{AttrFn}      = "FHEM::Buienradar::Attr";
    $hash->{FW_detailFn} = "FHEM::Buienradar::Detail";
    $hash->{AttrList}    = join(' ',
        (
            'disabled:on,off',
            'region:nl,de',
            'interval:10,60,120,180,240,300'
        )
    ) . " $::readingFnAttributes";
    $hash->{".PNG"} = "";
    $hash->{REGION} = 'de';
}

sub Detail {
    my ( $FW_wname, $d, $room, $pageHash ) =
      @_;    # pageHash is set for summaryFn.
    my $hash = $::defs{$d};

    return if ( !defined( $hash->{URL} ) );

    if (::ReadingsVal($hash->{NAME}, "rainData", "unknown") ne "unknown") {
        return
            HTML($hash->{NAME})
                . "<p><a href="
                . $hash->{URL}
                . " target=_blank>Raw JSON data (new window)</a></p>"
    } else {
        return "<div><a href='$hash->{URL}'>Raw JSON data (new window)</a></div>";
    }
}

#####################################
sub Undefine {

    my ( $hash, $arg ) = @_;

    ::RemoveInternalTimer( $hash, "FHEM::Buienradar::Timer" );
    return undef;
}

sub TimeCalc {

    # TimeA - TimeB
    my ( $timeA, $timeB ) = @_;

    my @AtimeA = split /:/, $timeA;
    my @AtimeB = split /:/, $timeB;

    if ( $AtimeA[0] < $AtimeB[0] ) {
        $AtimeA[0] += 24;
    }

    if ( ( $AtimeA[1] < $AtimeB[1] ) && ( $AtimeA[0] != $AtimeB[0] ) ) {
        $AtimeA[1] += 60;
    }

    my $result = ( $AtimeA[0] - $AtimeB[0] ) * 60 + $AtimeA[1] - $AtimeB[1];

    return int($result);
}

###################################
sub Get {

    my ( $hash, $name, $opt, @args ) = @_;

    return "\"get $name\" needs at least one argument" unless ( defined($opt) );

    given($opt) {
        when ("version") {
            return $version;
        }
    }

    if ( $opt eq "rainDuration" ) {
        ::ReadingsVal($name, "rainDuration", "unknown");
    }
    elsif ( $opt eq "refresh" ) {
        RequestUpdate($hash);
        return "";
    }
    elsif ( $opt eq "startsIn" ) {
        my $begin = ::ReadingsVal( $name, "rainBegin", "unknown" );
        my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) =
          localtime(time);
        my $result = "";

        if ( $begin ne "unknown" ) {

            $result = TimeCalc( $begin, "$hour:$min" );

            if ( $result < 0 ) {
                $result = "raining";
            }
            return $result;
        }
        return "no rain";
    }
    else {
        return "Unknown argument $opt, choose one of version:noArg refresh:noArg startsIn:noArg rainDuration:noArg";
    }
}

sub Attr {
    my ($command, $device_name, $attribute_name, $attribute_value) = @_;
    my $hash = $::defs{$device_name};

    Debugging(
        "Attr called", "\n",
        Dumper (
            $command, $device_name, $attribute_name, $attribute_value
        )
    );

    given ($attribute_name) {
        when ('disabled') {
            Debugging(
                Dumper (
                    {
                        'attribute_value' => $attribute_value,
                        'attr' => 'disabled',
                        "command" => $command,
                    }
                )
            );

            given ($command) {
                when ('set') {
                    return "${attribute_value} is not a valid value for disabled. Only 'on' or 'off' are allowed!"
                        if $attribute_value !~ /^(on|off|0|1)$/;

                    if ($attribute_value =~ /(on|1)/) {
                        ::RemoveInternalTimer( $hash, "FHEM::Buienradar::Timer" );
                        $hash->{NEXTUPDATE} = undef;
                        $hash->{STATE} = "inactive";
                        # this is a workaround: ::IsDisabled checks only for "disable", but not for "disabled"
                        #   so manually set $::attr{$device_name}{"disable"} without calling Buienradar::Attr
                        $::attr{$device_name}{"disable"} = 1;
                        return undef;
                    }

                    if ($attribute_value =~ /(off|0)/) {
                        Timer($hash);
                        # this is a workaround: ::IsDisabled checks only for "disable", but not for "disabled"
                        #   so manually set $::attr{$device_name}{"disable"} without calling Buienradar::Attr
                        delete $::attr{$device_name}{"disable"};
                        return undef;
                    }
                }

                when ('del') {
                    Timer($hash) if $attribute_value eq "off";
                }
            }
        }

        when ('region') {
            return "${attribute_value} is no valid value for region. Only 'de' or 'nl' are allowed!"
                if $attribute_value !~ /^(de|nl)$/ and $command eq "set";

            given ($command) {
                when ("set") {
                    $hash->{REGION} = $attribute_value;
                }

                when ("del") {
                    $hash->{REGION} = "nl";
                }
            }

            RequestUpdate($hash);
            return undef;
        }

        when ("interval") {
            return "${attribute_value} is no valid value for interval. Only 10, 60, 120, 180, 240 or 300 are allowed!"
                if $attribute_value !~ /^(10|60|120|180|240|300)$/ and $command eq "set";

            given ($command) {
                when ("set") {
                    $hash->{INTERVAL} = $attribute_value;
                }

                when ("del") {
                    $hash->{INTERVAL} = $FHEM::Buienradar::default_interval;
                }
            }

            Timer($hash);
            return undef;
        }

    }
}

sub TimeNowDiff {
   my $begin = $_[0];
   my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime(time);
   my $result = 0;
   $result = TimeCalc( $begin, "$hour:$min" );
   return $result;
}

#####################################
sub Define {

    my ( $hash, $def ) = @_;

    my @a = split( "[ \t][ \t]*", $def );
    my $latitude;
    my $longitude;

    if ( ( int(@a) == 2 ) && ( ::AttrVal( "global", "latitude", -255 ) != -255 ) )
    {
        $latitude  = ::AttrVal( "global", "latitude",  51.0 );
        $longitude = ::AttrVal( "global", "longitude", 7.0 );
    }
    elsif ( int(@a) == 4 ) {
        $latitude  = $a[2];
        $longitude = $a[3];
    }
    else {
        return
          int(@a)
          . " Syntax: define <name> Buienradar [<latitude> <longitude>]";
    }

    ::readingsSingleUpdate($hash, 'state', 'Initialized', 1);

    my $name = $a[0];
    $device = $name;

    $hash->{VERSION}    = $version;
    $hash->{INTERVAL}   = $FHEM::Buienradar::default_interval;
    $hash->{LATITUDE}   = $latitude;
    $hash->{LONGITUDE}  = $longitude;
    $hash->{URL}        = undef;
    $hash->{".HTML"}    = "<DIV>";

    ::readingsBeginUpdate($hash);
        ::readingsBulkUpdate( $hash, "rainNow", "unknown" );
        ::readingsBulkUpdate( $hash, "rainDataStart", "unknown");
        ::readingsBulkUpdate( $hash, "rainBegin", "unknown");
        ::readingsBulkUpdate( $hash, "rainEnd", "unknown");
    ::readingsEndUpdate( $hash, 1 );

    # set default region nl
    ::CommandAttr(undef, $name . ' region nl')
        unless (::AttrVal($name, 'region', undef));

    ::CommandAttr(undef, $name . ' interval ' . $FHEM::Buienradar::default_interval)
        unless (::AttrVal($name, 'interval', undef));

    Timer($hash);

    return undef;
}

sub Timer {
    my ($hash) = @_;
    my $nextupdate = 0;

    ::RemoveInternalTimer( $hash, "FHEM::Buienradar::Timer" );

    $nextupdate = int( time() + $hash->{INTERVAL} );
    $hash->{NEXTUPDATE} = ::FmtDateTime($nextupdate);
    RequestUpdate($hash);

    ::InternalTimer( $nextupdate, "FHEM::Buienradar::Timer", $hash );

    return 1;
}

sub RequestUpdate {
    my ($hash) = @_;
    my $region = $hash->{REGION};

    $hash->{URL} =
      ::AttrVal( $hash->{NAME}, "BaseUrl", "https://cdn-secure.buienalarm.nl/api/3.4/forecast.php" )
        . "?lat="       . $hash->{LATITUDE}
        . "&lon="       . $hash->{LONGITUDE}
        . '&region='    . $region
        . '&unit='      . 'mm/u';

    my $param = {
        url      => $hash->{URL},
        timeout  => 10,
        hash     => $hash,
        method   => "GET",
        callback => \&ParseHttpResponse
    };

    ::HttpUtils_NonblockingGet($param);
    ::Log3( $hash->{NAME}, 4, $hash->{NAME} . ": Update requested" );
}

sub HTML {
    my ( $name, $width ) = @_;
    my $hash = $::defs{$name};
    my @values = split /:/, ::ReadingsVal($name, "rainData", '0:0');

    my $as_html = <<'END_MESSAGE';
<style>

.BRchart div {
  font: 10px sans-serif;
  background-color: steelblue;
  text-align: right;
  padding: 3px;
  margin: 1px;
  color: white;
}
 
</style>
<div class="BRchart">
END_MESSAGE

    $as_html .= "<BR>Niederschlag (<a href=./fhem?detail=$name>$name</a>)<BR>";

    $as_html .= ::ReadingsVal( $name, "rainDataStart", "unknown" ) . "<BR>";
    my $factor =
      ( $width ? $width : 700 ) / ( 1 + ::ReadingsVal( $name, "rainMax", "0" ) );
    foreach my $val (@values) {
        $as_html .=
            '<div style="width: '
          . ( int( $val * $factor ) + 30 ) . 'px;">'
          . sprintf( "%.3f", $val )
          . '</div>';
    }

    $as_html .= "</DIV><BR>";
    return ($as_html);
}

=item C<FHEM::Buienradar::GChart>

C<FHEM::Buienradar::GChart> returns the precipitation data from buienradar.nl as PNG, renderd by Google Charts as
a PNG data.

=cut
sub GChart {
    my $name = shift;
    my $hash = $::defs{$name};

    unless ($hash->{'.SERIALIZED'}) {
        ::Log3($name, 3,
            sprintf(
                "[%s] Can't return serizalized data for FHEM::Buienradar::GChart.",
                $name
            )
        );

        # return dummy data
        return undef;
    }

    # read & parse stored data
    my %storedData = %{ Storable::thaw($hash->{".SERIALIZED"}) };
    my $data = join ', ', map {
        my ($k, $v) = (
            strftime('%H:%M', localtime $storedData{$_}{'start'}),
            sprintf('%.3f', $storedData{$_}{'precipiation'})
        );
        "['$k', $v]"
    } sort keys %storedData;

    # get language for language dependend legend
    my $language = lc ::AttrVal("global", "language", "DE");

    # create data for the GChart
    my $hAxis   = $FHEM::Buienradar::Translations{'GChart'}{'hAxis'}{$language};
    my $vAxis   = $FHEM::Buienradar::Translations{'GChart'}{'vAxis'}{$language};
    my $title   = sprintf(
        $FHEM::Buienradar::Translations{'GChart'}{'title'}{$language},
        $hash->{LATITUDE},
        $hash->{LONGITUDE}
    );
    my $legend  = $FHEM::Buienradar::Translations{'GChart'}{'legend'}{$language};

    return <<"CHART"
<div id="chart_${name}"; style="width:100%; height:100%"></div>
<script type="text/javascript" src="https://www.gstatic.com/charts/loader.js"></script>
<script type="text/javascript">

    google.charts.load("current", {packages:["corechart"]});
    google.charts.setOnLoadCallback(drawChart);
    function drawChart() {
        var data = google.visualization.arrayToDataTable([
            ['string', '${legend}'],
            ${data}
        ]);

        var options = {
            title: "${title}",
            hAxis: {
                title: "${hAxis}",
                slantedText:true,
                slantedTextAngle: 45,
                textStyle: {
                    fontSize: 10}
            },
            vAxis: {
                minValue: 0,
                title: "${vAxis}"
            }
        };

        var my_div = document.getElementById(
            "chart_${name}");        var chart = new google.visualization.AreaChart(my_div);
        google.visualization.events.addListener(chart, 'ready', function () {
            my_div.innerHTML = '<img src="' + chart.getImageURI() + '">';
        });

        chart.draw(data, options);}
</script>

CHART
}

=pod

=item C<FHEM::Buienradar::ColourBarChart>

C<FHEM::Buienradar::ColourBarChart> is a colourful single line bar chart.

=cut
sub ColourBarChart {
    my $name = shift;
    my $hash = $::defs{$name};

    unless ($hash->{'.SERIALIZED'}) {
        ::Log3($name, 3,
            sprintf(
                "[%s] Can't return serizalized data for FHEM::Buienradar::ColourBarChart.",
                $name
            )
        );
    }

    my %storedData = %{ Storable::thaw($hash->{".SERIALIZED"}) };
    my @storedData_keys = sort keys %storedData;
    my @severity_conditions_sorted = sort {$b <=> $a} keys %severity_conditions;
    my @timestamps;
    my $data = join "\n", map {
        my $precip = $storedData{$_}{'precipiation'};
        my $severity_label = undef;
        my $start = POSIX::strftime('%H:%M', localtime $storedData{$_}{'start'});
        push @timestamps, $start;

        foreach my $sev_index (@severity_conditions_sorted) {
            $severity_label = $severity_conditions{$sev_index};
            last if $precip >= $sev_index;
        }

        sprintf(
            '<td class="%s" title="%s, %.3f mm/h" />',
            $severity_label, $start, $precip
        );
    } @storedData_keys;

    my @legend;
    for(my $ts_index, my $max = scalar @timestamps; $ts_index < $max; $ts_index++) {
        if($ts_index % 5 == 0) {
            push @legend, "<td>$timestamps[$ts_index]</td>";
        } else {
            push @legend, "<td />";
        }
    }

    my $colourBarChart = <<~"END_MESSAGE";
    <style type="text/css">
        div.buienradar table {
            empty-cells: show;
            width: 70%
        }

        div.buienradar table td {
            height: 3ex;
            width: 2ex;
        }

        div.buienradar table td.tropical {
            background-color: firebrick;
        }

        div.buienradar table td.rainstorm {
            background-color: blueviolet;
        }

        div.buienradar table td.heavy {
            background-color: royalblue;
        }

        div.buienradar table td.mediumheavy {
            background-color: steelblue;
        }

        div.buienradar table td.medium {
            background-color: dodgerblue;
        }

        div.buienradar table td.lightmedium {
            background-color: deepskyblue;
        }

        div.buienradar table td.light {
            background-color: lightskyblue;
        }

        div.buienradar table td.drizzle {
            background-color: powderblue;
        }

        div.buienradar table td.none {
            background-color: white;
        }
    </style>
    <div class="buienradar">
        <table>
            <tr>
                @legend
            </tr>
            <tr>
                $data
            </tr>
        </table>
    </div>

    END_MESSAGE

    return $colourBarChart;
}

=pod

=item C<FHEM::Buienradar::LogProxy>

C<FHEM::Buienradar::LogProxy> returns FHEM log look-alike data from the current data for using it with
FTUI. It returns a list containing three elements:

=over 1

=item Log look-alike data, like

=begin text

2019-08-05_14:40:00 0.000
2019-08-05_13:45:00 0.000
2019-08-05_14:25:00 0.000
2019-08-05_15:15:00 0.000
2019-08-05_14:55:00 0.000
2019-08-05_15:30:00 0.000
2019-08-05_14:45:00 0.000
2019-08-05_15:25:00 0.000
2019-08-05_13:30:00 0.000
2019-08-05_13:50:00 0.000

=end text

=item Fixed value of 0

=item Maximal amount of rain in a 5 minute interval

=back

=cut
sub LogProxy {
    my $name = shift;
    my $hash = $::defs{$name};

    unless ($hash->{'.SERIALIZED'}) {
        ::Log3($name, 3,
            sprintf(
                "[%s] Can't return serizalized data for FHEM::Buienradar::LogProxy. Using dummy data",
                $name
            )
        );

        # return dummy data
        return (0, 0, 0);
    }

    my %data = %{ Storable::thaw($hash->{".SERIALIZED"}) };

    return (
        join("\n", map {
            join(
                ' ', (
                    strftime('%F_%T', localtime $data{$_}{'start'}),
                    sprintf('%.3f', $data{$_}{'precipiation'})
                )
            )
        } keys %data),
        0,
        ::ReadingsVal($name, "rainMax", 0)
    );
}

sub TextChart {
    my $name = shift;
    my $hash = $::defs{$name};

    unless ($hash->{'.SERIALIZED'}) {
        ::Log3($name, 3,
            sprintf(
                "[%s] Can't return serizalized data for FHEM::Buienradar::TextChart.",
                $name
            )
        );

        # return dummy data
        return undef;
    }

    my %storedData = %{ Storable::thaw($hash->{".SERIALIZED"}) };

    my $data = join "\n", map {
        my ($time, $precip, $bar) = (
            strftime('%H:%M', localtime $storedData{$_}{'start'}),
            sprintf('% 7.3f', $storedData{$_}{'precipiation'}),
            (($storedData{$_}{'precipiation'} < 5) ? "=" x  POSIX::lround(abs($storedData{$_}{'precipiation'} * 10)) : ("=" x  50) . '>'),
        );
        "$time | $precip | $bar"
    } sort keys %storedData;

    return $data;
}

sub ParseHttpResponse {
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    #Debugging("*** RESULT ***");
    #Debugging(Dumper {param => $param, data => $data, error => $err});

    my %precipitation_forecast;

    if ( $err ne "" ) {
        # Debugging("$name: error while requesting " . $param->{url} . " - $err" );
        ::readingsSingleUpdate($hash, 'state', "Error: " . $err . " => " . $data, 1);
        ResetResult($hash);
    }
    elsif ( $data ne "" ) {
        # Debugging("$name returned: $data");
        my $forecast_data;
        my $error;

        if(defined $param->{'code'} && $param->{'code'} ne "200") {
            $error = sprintf(
                "Pulling %s returns HTTP status code %d instead of 200.",
                $hash->{URL},
                $param->{'code'}
            );
            ::Log3($name, 1, "[$name] $error");
            ::Log3($name, 3, "[$name] " . Dumper($param)) if ::AttrVal("global", "stacktrace", 0) eq "1";
            ::readingsSingleUpdate($hash, 'state', $error, 1);
            ResetResult($hash);
            return undef;
        }

        $forecast_data = eval { $forecast_data = from_json($data) } unless @errors;

        if ($@) {
            $error = sprintf(
                "Can't evaluate JSON from %s: %s",
                $hash->{URL},
                $@
            );
            ::Log3($name, 1, "[$name] $error");
            ::Log3($name, 3, "[$name] " . join("", map { "[$name] $_" } Dumper($data))) if ::AttrVal("global", "stacktrace", 0) eq "1";
            ::readingsSingleUpdate($hash, 'state', $error, 1);
            ResetResult($hash);
            return undef;
        }

        unless ($forecast_data->{'success'}) {
            $error = "Got JSON but buienradar.nl has some troubles delivering meaningful data!";
            ::Log3($name, 1, "[$name] $error");
            ::Log3($name, 3, "[$name] " . join("", map { "[$name] $_" } Dumper($data))) if ::AttrVal("global", "stacktrace", 0) eq "1";
            ::readingsSingleUpdate($hash, 'state', $error, 1);
            ResetResult($hash);
            return undef;
        }

        my @precip;
        @precip = @{$forecast_data->{"precip"}} unless @errors;

        ::Log3($name, 3, sprintf(
            "[%s] Parsed the following data from the buienradar JSON:\n%s",
            $name, join("", map { "[$name] $_" } Dumper(@precip))
        )) if ::AttrVal("global", "stacktrace", 0) eq "1";

        if (scalar @precip > 0) {
            my $rainLaMetric        = join(',', map {$_ * 1000} @precip[0..11]);
            my $rainTotal           = List::Util::sum @precip;
            my $rainMax             = List::Util::max @precip;
            my $rainStart           = undef;
            my $rainEnd             = undef;
            my $dataStart           = $forecast_data->{start};
            my $dataEnd             = $dataStart + (scalar @precip) * 5 * ONE_MINUTE;
            my $forecast_start      = $dataStart;
            my $rainNow             = undef;
            my $rainData            = join(':', @precip);
            my $rainAmount          = List::Util::sum @precip[0..11];
            my $isRaining           = undef;
            my $intervalsWithRain   = scalar map { $_ > 0 ? $_ : () } @precip;

            for (my $precip_index = 0; $precip_index < scalar @precip; $precip_index++) {

                my $start           = $forecast_start + $precip_index * 5 * ONE_MINUTE;
                my $end             = $start + 5 * ONE_MINUTE;
                my $precip          = $precip[$precip_index];
                $isRaining          = undef;                            # reset

                # set a flag if it's raining
                if ($precip > 0) {
                    $isRaining = 1;
                }

                # there is precipitation and start is not yet set
                if (!$rainStart and $isRaining) {
                    $rainStart  = $start;
                }

                # It's raining again, so we have to reset rainEnd for a new chance
                if ($isRaining and $rainEnd) {
                    $rainEnd    = undef;
                }

                # It's not longer raining, so set rainEnd (again)
                if ($rainStart and !$isRaining and !$rainEnd) {
                    $rainEnd    = $start;
                }

                if (time() ~~ [$start..$end]) {
                    $rainNow    = $precip;
                }

                $precipitation_forecast{$start} = {
                    'start'        => $start,
                    'end'          => $end,
                    'precipiation' => $precip,
                };
            }

            $hash->{".SERIALIZED"} = Storable::freeze(\%precipitation_forecast);

            ::readingsBeginUpdate($hash);
                ::readingsBulkUpdate( $hash, "state", (($rainNow) ? sprintf( "%.3f", $rainNow) : "unknown"));
                ::readingsBulkUpdate( $hash, "rainTotal", sprintf( "%.3f", $rainTotal) );
                ::readingsBulkUpdate( $hash, "rainAmount", sprintf( "%.3f", $rainAmount) );
                ::readingsBulkUpdate( $hash, "rainNow", (($rainNow) ? sprintf( "%.3f", $rainNow) : "unknown"));
                ::readingsBulkUpdate( $hash, "rainLaMetric", $rainLaMetric );
                ::readingsBulkUpdate( $hash, "rainDataStart", strftime "%R", localtime $dataStart);
                ::readingsBulkUpdate( $hash, "rainDataEnd", strftime "%R", localtime $dataEnd );
                ::readingsBulkUpdate( $hash, "rainMax", sprintf( "%.3f", $rainMax ) );
                ::readingsBulkUpdate( $hash, "rainBegin", (($rainStart) ? strftime "%R", localtime $rainStart : 'unknown'));
                ::readingsBulkUpdate( $hash, "rainEnd", (($rainEnd) ? strftime "%R", localtime $rainEnd : 'unknown'));
                ::readingsBulkUpdate( $hash, "rainData", $rainData);
                ::readingsBulkUpdate( $hash, "rainDuration", $intervalsWithRain * 5);
                ::readingsBulkUpdate( $hash, "rainDurationIntervals", $intervalsWithRain);
                ::readingsBulkUpdate( $hash, "rainDurationPercent", ($intervalsWithRain / scalar @precip) * 100);
                ::readingsBulkUpdate( $hash, "rainDurationTime", sprintf("%02d:%02d",(( $intervalsWithRain * 5 / 60), $intervalsWithRain * 5 % 60)));
            ::readingsEndUpdate( $hash, 1 );
        }
    }
}

sub ResetResult {
    my $hash = shift;

    $hash->{'.SERIALIZED'} = undef;

    ::readingsBeginUpdate($hash);
        ::readingsBulkUpdate( $hash, "rainTotal", "unknown" );
        ::readingsBulkUpdate( $hash, "rainAmount", "unknown" );
        ::readingsBulkUpdate( $hash, "rainNow", "unknown" );
        ::readingsBulkUpdate( $hash, "rainLaMetric", "unknown" );
        ::readingsBulkUpdate( $hash, "rainDataStart", "unknown");
        ::readingsBulkUpdate( $hash, "rainDataEnd", "unknown" );
        ::readingsBulkUpdate( $hash, "rainMax", "unknown" );
        ::readingsBulkUpdate( $hash, "rainBegin", "unknown");
        ::readingsBulkUpdate( $hash, "rainEnd", "unknown");
        ::readingsBulkUpdate( $hash, "rainData", "unknown");
    ::readingsEndUpdate( $hash, 1 );
}

sub Debugging {
    local $OFS = "\n";
    ::Debug("@_") if ::AttrVal("global", "verbose", undef) eq "4" or ::AttrVal($device, "debug", 0) eq "1";
}

1;

=pod

=encoding utf8

=item helper
=item summary Precipitation forecasts based on buienradar.nl
=item summary_DE Niederschlagsvorhersage auf Basis des Wetterdienstes buienradar.nl



=begin html

<span id="Buienradar"></span>
<h2 id="buienradar">Buienradar</h2>
<p>Buienradar provides access to precipitation forecasts by the dutch service <a href="https://www.buienradar.nl">Buienradar.nl</a>.</p>
<p><span id="Buienradardefine"></span></p>
<h3 id="define">Define</h3>
<pre><code>define &lt;devicename&gt; Buienradar [latitude] [longitude]
</code></pre>
<p><var>latitude</var> and <var>longitude</var> are facultative and will gathered from <var>global</var> if not set. So the smallest possible definition is:</p>
<pre><code>define &lt;devicename&gt; Buienradar
</code></pre><span id="Buienradarget"></span>
<h3 id="get">Get</h3>
<p><var>Get</var> will get you the following:</p>
<ul>
  <li><code>rainDuration</code> - predicted duration of the next precipitation in minutes.</li>
  <li><code>startse</code> - next precipitation starts in <var>n</var> minutes. <strong>Obsolete!</strong></li>
  <li><code>refresh</code> - get new data from Buienradar.nl.</li>
  <li><code>version</code> - get current version of the Buienradar module.</li>
</ul><span id="Buienradarreadings"></span>
<h3 id="readings">Readings</h3>
<p>Buienradar provides several readings:</p>
<ul>
  <li><code>rainAmount</code> - amount of predicted precipitation in mm/h for the next hour.</li>
  <li><code>rainBegin</code> - starting time of the next precipitation, <var>unknown</var> if no precipitation is predicted.</li>
  <li><code>raindEnd</code> - ending time of the next precipitation, <var>unknown</var> if no precipitation is predicted.</li>
  <li><code>rainDataStart</code> - starting time of gathered data.</li>
  <li><code>rainDataEnd</code> - ending time of gathered data.</li>
  <li><code>rainLaMetric</code> - data formatted for a LaMetric device.</li>
  <li><code>rainMax</code> - maximal amount of precipitation for <strong>any</strong> 5 minute interval of the gathered data in mm/h.</li>
  <li><code>rainNow</code> - amount of precipitation for the <strong>current</strong> 5 minute interval in mm/h.</li>
  <li><code>rainTotal</code> - total amount of precipition for the gathered data in mm/h.</li>
  <li><code>rainDuration</code> - duration of the precipitation contained in the forecast</li>
  <li><code>rainDurationTime</code> - duration of the precipitation contained in the forecast in HH:MM</li>
  <li><code>rainDurationIntervals</code> - amount of intervals with precipitation</li>
  <li><code>rainDurationPercent</code> - percentage of interavls with precipitation</li>
</ul><span id="Buienradarattr"></span>
<h3 id="attributes">Attributes</h3>
<ul>
  <li>
    <a name="disabled" id="disabled"></a> <code>disabled on|off</code> - If <code>disabled</code> is set to <code>on</code>, no further requests to Buienradar.nl will be performed. <code>off</code> reactivates the device, also if the attribute ist simply deleted.
  </li>
  <li>
    <a name="region" id="region"></a> <code>region nl|de</code> - Allowed values are <code>nl</code> (default value) and <code>de</code>. In some cases, especially in the south and east of Germany, <code>de</code> returns values at all.
  </li>
  <li>
    <a name="interval" id="interval"></a> <code>interval 10|60|120|180|240|300</code> - Data update every <var>n</var> seconds. <strong>Attention!</strong> 10 seconds is a very aggressive value and should be chosen carefully, <abbr>e.g.</abbr> when troubleshooting. The default value is 120 seconds.
  </li>
</ul>
<h3 id="visualisation">Visualisation</h3>
<p>Buienradar offers besides the usual view as device also the possibility to visualize the data as charts in different formats.</p>
<ul>
  <li>
    <p>An HTML version that is displayed in the detail view by default and can be viewed with</p>
    <pre><code>  { FHEM::Buienradar::HTML("buienradar device name")}
</code></pre>
    <p>can be retrieved.</p>
  </li>
  <li>
    <p>A chart generated by Google Charts in <abbr>PNG</abbr> format, which can be viewed with</p>
    <pre><code>  { FHEM::Buienradar::GChart("buienradar device name")}
</code></pre>
    <p>can be retrieved. <strong>Caution!</strong> Please note that data is transferred to Google for this purpose!</p>
  </li>
  <li>
    <p><abbr>FTUI</abbr> is supported by the LogProxy format:</p>
    <pre><code>  { FHEM::Buienradar::LogProxy("buienradar device name")}
</code></pre>
  </li>
  <li>
    <p>A plain text representation can be display by</p>
    <pre><code>  { FHEM::Buienradar::TextChart("buienradar device name")}
</code></pre>
    <p>Every line represents a record of the whole set in a format like</p>
    <pre><code>  22:25 |   0.060 | =
  22:30 |   0.370 | ====
  22:35 |   0.650 | =======
</code></pre>
    <p>For every 0.1 mm/h precipitation a <code>=</code> is displayed, but the output is capped to 50 units. If more than 50 units would be display, the bar is appended with a <code>&gt;</code>.</p>
    <pre><code>  23:00 |  11.800 | ==================================================&gt;
</code></pre>
  </li>
  <li>
    <p>A compact graphical representation is displayed with</p>
    <pre><code>  { FHEM::Buienradar::ColourBarChart("buienradar device name") }
</code></pre>
    <p>is shown. A two-line HTML table formatted with CSS is generated; for each value a single cell with different blue intensity as background colour and a legend is depicted.</p>
  </li>
</ul>

=end html

=begin html_DE

<span id="Buienradar"></span>
<h2 id="buienradar">Buienradar</h2>
<p>Das Buienradar-Modul bindet die Niederschlagsvorhersagedaten der freien <abbr title="Application Program Interface">API</abbr> von <a href="https://www.buienradar.nl">Buienradar.nl</a> an.</p>
<p><span id="Buienradardefine"></span></p>
<h3 id="define">Define</h3>
<pre><code>define &lt;devicename&gt; Buienradar [latitude] [longitude]
</code></pre>
<p>Die Werte für latitude und longitude sind optional und werden, wenn nicht explizit angegeben, von <var>global</var> bezogen. Die minimalste Definition lautet demnach:</p>
<pre><code>define &lt;devicename&gt; Buienradar
</code></pre><span id="Buienradarget"></span>
<h3 id="get">Get</h3>
<p>Aktuell lassen sich folgende Daten mit einem Get-Aufruf beziehen:</p>
<ul>
  <li><code>rainDuration</code> - Die voraussichtliche Dauer des nächsten Niederschlags in Minuten.</li>
  <li><code>startse</code> - Der nächste Niederschlag beginnt in <var>n</var> Minuten. <strong>Obsolet!</strong></li>
  <li><code>refresh</code> - Neue Daten abfragen.</li>
  <li><code>version</code> - Aktuelle Version abfragen.</li>
</ul><span id="Buienradarreadings"></span>
<h3 id="readings">Readings</h3>
<p>Aktuell liefert Buienradar folgende Readings:</p>
<ul>
  <li><code>rainAmount</code> - Menge des gemeldeten Niederschlags für die nächste Stunde in mm/h.</li>
  <li><code>rainBegin</code> - Beginn des nächsten Niederschlag. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.</li>
  <li><code>raindEnd</code> - Ende des nächsten Niederschlag. Wenn kein Niederschlag gemeldet ist, <var>unknown</var>.</li>
  <li><code>rainDataStart</code> - Zeitlicher Beginn der gelieferten Niederschlagsdaten.</li>
  <li><code>rainDataEnd</code> - Zeitliches Ende der gelieferten Niederschlagsdaten.</li>
  <li><code>rainLaMetric</code> - Aufbereitete Daten für LaMetric-Devices.</li>
  <li><code>rainMax</code> - Die maximale Niederschlagsmenge in mm/h für ein 5 Min. Intervall auf Basis der vorliegenden Daten.</li>
  <li><code>rainNow</code> - Die vorhergesagte Niederschlagsmenge für das aktuelle 5 Min. Intervall in mm/h.</li>
  <li><code>rainTotal</code> - Die gesamte vorhergesagte Niederschlagsmenge in mm/h</li>
  <li><code>rainDuration</code> - Dauer der gemeldeten Niederschläge in Minuten</li>
  <li><code>rainDurationTime</code> - Dauer der gemeldeten Niederschläge in HH:MM</li>
  <li><code>rainDurationIntervals</code> - Anzahl der Intervalle mit gemeldeten Niederschlägen</li>
  <li><code>rainDurationPercent</code> - Prozentualer Anteil der Intervalle mit Niederschlägen</li>
</ul><span id="Buienradarattr"></span>
<h3 id="attribute">Attribute</h3>
<ul>
  <li>
    <a name="disabled" id="disabled"></a> <code>disabled on|off</code> - Wenn <code>disabled</code> auf <code>on</code> gesetzt wird, wird das Device keine weiteren Anfragen mehr an Buienradar.nl durchführen. <code>off</code> reaktiviert das Modul, ebenso wenn das Attribut gelöscht wird.
  </li>
  <li>
    <a name="region" id="region"></a> <code>region nl|de</code> - Erlaubte Werte sind <code>nl</code> (Standardwert) und <code>de</code>. In einigen Fällen, insbesondere im Süden und Osten Deutschlands, liefert <code>de</code> überhaupt Werte.
  </li>
  <li>
    <a name="interval" id="interval"></a> <code>interval 10|60|120|180|240|300</code> - Aktualisierung der Daten alle <var>n</var> Sekunden. <strong>Achtung!</strong> 10 Sekunden ist ein sehr aggressiver Wert und sollte mit Bedacht gewählt werden, <abbr>z.B.</abbr> bei der Fehlersuche. Standardwert sind 120 Sekunden.
  </li>
</ul>
<h3 id="visualisierungen">Visualisierungen</h3>
<p>Buienradar bietet neben der üblichen Ansicht als Device auch die Möglichkeit, die Daten als Charts in verschiedenen Formaten zu visualisieren.</p>
<ul>
  <li>
    <p>Eine HTML-Version die in der Detailansicht standardmäßig eingeblendet wird und mit</p>
    <pre><code>  { FHEM::Buienradar::HTML("name des buienradar device")}
</code></pre>
    <p>abgerufen werden.</p>
  </li>
  <li>
    <p>Ein von Google Charts generiertes Diagramm im <abbr>PNG</abbr>-Format, welcher mit</p>
    <pre><code>  { FHEM::Buienradar::GChart("name des buienradar device")}
</code></pre>
    <p>abgerufen werden kann. <strong>Achtung!</strong> Dazu werden Daten an Google übertragen!</p>
  </li>
  <li>
    <p>Für <abbr>FTUI</abbr> werden die Daten im LogProxy-Format bereitgestellt:</p>
    <pre><code>  { FHEM::Buienradar::LogProxy("name des buienradar device")}
</code></pre>
  </li>
  <li>
    <p>Für eine reine Text-Ausgabe der Daten als Graph, kann</p>
    <pre><code>  { FHEM::Buienradar::TextChart("name des buienradar device")}
</code></pre>
    <p>verwendet werden. Ausgegeben wird ein für jeden Datensatz eine Zeile im Muster</p>
    <pre><code>  22:25 |   0.060 | =
  22:30 |   0.370 | ====
  22:35 |   0.650 | =======
</code></pre>
    <p>wobei für jede 0.1 mm/h Niederschlag ein <code>=</code> ausgegeben wird, maximal jedoch 50 Einheiten. Mehr werden mit einem <code>&gt;</code> abgekürzt.</p>
    <pre><code>  23:00 |  11.800 | ==================================================&gt;
</code></pre>
  </li>
  <li>
    <p>Eine kompakte graphische Darstellung wird mit</p>
    <pre><code>  { FHEM::Buienradar::ColourBarChart("Name des Buienradar-Devices") }
</code></pre>
    <p>dargestellt. Erzeugt wird eine zweizeilige, mit CSS formatierte HTML-Tabelle, die für jeden Wert eine eigene Zelle mit unterschiedlicher Blauintensität als Hintergrundfarbe und eine Legende abbildet.</p>
  </li>
</ul>

=end html_DE

=for :application/json;q=META.json 59_Buienradar.pm
{
    "abstract": "FHEM module for precipiation forecasts basing on buienradar.nl",
    "x_lang": {
        "de": {
            "abstract": "FHEM-Modul f&uuml;r Regen- und Regenmengenvorhersagen auf Basis von buienradar.nl"
        }
    },
    "keywords": [
        "Buienradar",
        "Precipiation",
        "Rengenmenge",
        "Regenvorhersage",
        "hoeveelheid regen",
        "regenvoorspelling",
        "Niederschlag"
    ],
    "release_status": "development",
    "license": "Unlicense",
    "version": "2.3.2",
    "author": [
        "Christoph Morrison <post@christoph-jeschke.de>"
    ],
    "resources": {
        "homepage": "https://github.com/fhem/mod-Buienradar/",
        "x_homepage_title": "Module homepage",
        "license": [
            "https://github.com/fhem/mod-Buienradar/blob/master/LICENSE"
        ],
        "bugtracker": {
            "web": "https://github.com/fhem/mod-Buienradar/issues"
        },
        "repository": {
            "type": "git",
            "url": "https://github.com/fhem/mod-Buienradar.git",
            "web": "https://github.com/fhem/mod-Buienradar.git",
            "x_branch": "master",
            "x_development": {
                "type": "git",
                "url": "https://github.com/fhem/mod-Buienradar.git",
                "web": "https://github.com/fhem/mod-Buienradar/tree/development",
                "x_branch": "development"
            },
            "x_filepath": "",
            "x_raw": ""
        },
        "x_wiki": {
            "title": "Buienradar",
            "web": "https://wiki.fhem.de/wiki/Buienradar"
        }
    },
    "x_fhem_maintainer": [
        "jeschkec"
    ],
    "x_fhem_maintainer_github": [
        "christoph-morrison"
    ],
    "prereqs": {
        "runtime": {
            "requires": {
                "FHEM": 5.00918799,
                "perl": 5.10,
                "Meta": 0,
                "JSON": 0
            },
            "recommends": {
            
            },
            "suggests": {
            
            }
        }
    }
}
=end :application/json;q=META.json

=cut



