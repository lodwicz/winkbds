#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use JSON::PP;
use Getopt::Long qw(GetOptions);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

# ------------------------------------------------------------
# Command-line options
#
# Default: compact ANSI
# --iso:    ISO 105
# --ansi:   extended ANSI 104
# --cool:   Keycool 84
# ------------------------------------------------------------

Getopt::Long::Configure('no_auto_abbrev');

my ($opt_iso, $opt_ansi, $opt_cool);

GetOptions(
    'iso'  => \$opt_iso,
    'ansi' => \$opt_ansi,
    'cool' => \$opt_cool,
) or die "Usage: perl pkl2kle.pl [--iso | --ansi | --cool] input.pkl [output.json]\n";

my $selected = ($opt_iso || 0) + ($opt_ansi || 0) + ($opt_cool || 0);

die "Choose only one keyboard option\n"
    if $selected > 1;

my $keyboard =
    $opt_iso  ? 'iso'  :
    $opt_ansi ? 'ansi' :
    $opt_cool ? 'cool' :
                'compact';

my %keyboard_name = (
    compact => 'Compact ANSI',
    iso     => 'ISO 105',
    ansi    => 'ANSI 104',
    cool    => 'Keycool 84',
);

my $input = shift @ARGV
    or die "Usage: perl pkl2kle.pl [--iso | --ansi | --cool] input.pkl [output.json]\n";

my $output = shift @ARGV;

die "Too many arguments\n" if @ARGV;

# ------------------------------------------------------------
# Read PKL file
# ------------------------------------------------------------

open my $fh, '<:encoding(UTF-8)', $input
    or die "Cannot open $input: $!\n";

my $section = '';
my $layoutname = $input;

my @shiftstates;
my %layout;
my %deadkeys;

while (my $line = <$fh>) {

    chomp $line;
    $line =~ s/\r$//;

    next if $line =~ /^\s*$/;
    next if $line =~ /^\s*;/;

    # Section header
    if ($line =~ /^\s*\[([^\]]+)\]/) {
        $section = lc $1;
        next;
    }

    # --------------------------------------------------------
    # [informations]
    # --------------------------------------------------------

    if ($section eq 'informations') {

        if ($line =~ /^\s*layoutname\s*=\s*(.*?)\s*$/i) {
            $layoutname = $1;
        }

        next;
    }

    # --------------------------------------------------------
    # [global]
    # --------------------------------------------------------

    if ($section eq 'global') {

        if ($line =~ /^\s*shiftstates\s*=\s*(.*?)\s*$/i) {
            @shiftstates = split /:/, $1;
            s/^\s+|\s+$//g for @shiftstates;
        }

        next;
    }

    # --------------------------------------------------------
    # [layout]
    # --------------------------------------------------------

    if ($section eq 'layout') {

        next unless $line =~
            /^\s*(SC[0-9A-Fa-f]+)\s*=\s*(.*)$/;

        my ($sc, $rhs) = (uc($1), $2);

        # Preserve empty tab-separated fields.
        my @field = split /\t/, $rhs, -1;

        # Trim spaces, not tabs.
        s/^ +| +$//g for @field;

        my $expected = 2 + @shiftstates;

        die "Too few fields for $sc: "
            . scalar(@field) . " (expected at least $expected)\n"
            if @field < $expected;

        # Optional Caps and CapsSh fields.
        # A field beginning with ';' is a trailing comment.
        my $has_caps =
            @field >= $expected + 2
            && $field[$expected] !~ /^\s*;/;

        my ($vk, $capstat, @values) =
            @field[0 .. $expected - 1];

        my %key;
        @key{@shiftstates} = @values;

        $layout{$sc} = {
            vk      => $vk,
            capstat => $capstat,
            states  => \%key,
        };

        if ($has_caps) {
            $layout{$sc}{caps}   = $field[$expected];
            $layout{$sc}{capssh} = $field[$expected + 1];
        }

        next;
    }

    # --------------------------------------------------------
    # [deadkeyN]
    # --------------------------------------------------------

    if ($section =~ /^deadkey\d+$/) {

        if ($line =~ /^\s*(\d+)\s*=\s*(.*?)\s*$/) {

            my ($key, $value) = ($1, $2);

            $value =~ s/\s+;.*$//;

            $deadkeys{$section}{$key} = $value;
        }

        next;
    }
}

close $fh;

die "No shiftstates declaration found\n"
    unless @shiftstates;

# ------------------------------------------------------------
# Convert PKL values into printable KLE legends
# ------------------------------------------------------------

sub display_value {

    my ($value) = @_;

    return '' if !defined $value || $value eq '--';

    if ($value =~ /^dk(\d+)$/i) {
        return "DK$1";
    }

    if ($value =~ /^=?\{(.+)\}$/) {
        return $1;
    }

    my %control = (
        "\x1b" => 'ESC',
        "\x1c" => 'FS',
        "\x1d" => 'GS',
        "\x1e" => 'RS',
        "\x1f" => 'US',
        "\x7f" => 'DEL',
    );

    return $control{$value} if exists $control{$value};

    return '' if $value =~ /[\x00-\x1f\x7f]/;

    return $value;
}

# ------------------------------------------------------------
# Construct KLE legend.
#
# KLE positions:
#   top-left     = Shift
#   bottom-left  = Normal
#   top-right    = Shift+AltGr
#   bottom-right = AltGr
# ------------------------------------------------------------

sub key_label {

    my ($sc, $fallback) = @_;

    return $fallback unless exists $layout{$sc};

    my $states = $layout{$sc}{states};

    my @legend = (
        display_value($states->{1}),
        display_value($states->{0}),
        display_value($states->{7}),
        display_value($states->{6}),
    );

    return $fallback unless grep { length } @legend;

    return join "\n", @legend;
}

# ------------------------------------------------------------
# Add a PKL-mapped key to a KLE row.
# ------------------------------------------------------------

sub add_key {

    my ($row, $sc, $fallback, $width, $height) = @_;

    my %props;

    $props{w} = $width
        if defined $width && $width != 1;

    $props{h} = $height
        if defined $height && $height != 1;

    push @$row, \%props if %props;

    push @$row, key_label($sc, $fallback);
}

# Add a fixed-label key.
sub add_fixed_key {

    my ($row, $label, $width, $height) = @_;

    my %props;

    $props{w} = $width
        if defined $width && $width != 1;

    $props{h} = $height
        if defined $height && $height != 1;

    push @$row, \%props if %props;

    push @$row, $label;
}

# Add a KLE alignment property.
sub align {

    my ($row, $alignment) = @_;

    push @$row, { a => $alignment };
}

# Add horizontal spacing.
sub gap {

    my ($row, $width) = @_;

    push @$row, { x => $width };
}

# ISO Enter: composite, two-row key.
=begin comment 
sub add_iso_enter {

    my ($row, $sc, $fallback) = @_;

    push @$row, {
        x  => 0.25,
        w  => 1.25,
        h  => 2,
        w2 => 1.5,
        h2 => 1,
        x2 => -0.25,
        y2 => 1,
    };

    push @$row, key_label($sc, $fallback);
}
=end comment
=cut 

sub add_iso_enter {

    my ($row, $sc, $fallback) = @_;

    push @$row, {
        x  => 0.25,
        w  => 1.25,
        h  => 2,
        w2 => 1.5,
        h2 => 1,
        x2 => -0.25,
        # y2 => 1,
    };

    push @$row, key_label($sc, $fallback);
}
# ------------------------------------------------------------
# Compact ANSI geometry (~61 keys)
# ------------------------------------------------------------

sub build_compact_ansi {

    my @rows;

    # --------------------------------------------------------
    # Number row
    # --------------------------------------------------------

    {
        my @r;

        add_key(\@r, 'SC029', '`');

        for my $sc (qw(
            SC002 SC003 SC004 SC005 SC006 SC007
            SC008 SC009 SC00A SC00B SC00C SC00D
        )) {
            add_key(\@r, $sc, '');
        }

        add_key(\@r, 'SC00E', 'Backspace', 2);

        push @rows, \@r;
    }

    # --------------------------------------------------------
    # QWERTY row
    # --------------------------------------------------------

    {
        my @r;

        add_key(\@r, 'SC00F', 'Tab', 1.5);

        for my $sc (qw(
            SC010 SC011 SC012 SC013 SC014 SC015
            SC016 SC017 SC018 SC019 SC01A SC01B
        )) {
            add_key(\@r, $sc, '');
        }

        add_key(\@r, 'SC02B', '\\', 1.5);

        push @rows, \@r;
    }

    # --------------------------------------------------------
    # Home row
    # --------------------------------------------------------

    {
        my @r;

        add_key(\@r, 'SC03A', 'Caps', 1.75);

        for my $sc (qw(
            SC01E SC01F SC020 SC021 SC022
            SC023 SC024 SC025 SC026 SC027 SC028
        )) {
            add_key(\@r, $sc, '');
        }

        add_key(\@r, 'SC01C', 'Enter', 2.25);

        push @rows, \@r;
    }

    # --------------------------------------------------------
    # Bottom letter row
    # --------------------------------------------------------

    {
        my @r;

        add_key(\@r, 'SC02A', 'Shift', 2.25);

        for my $sc (qw(
            SC02C SC02D SC02E SC02F SC030
            SC031 SC032 SC033 SC034 SC035
        )) {
            add_key(\@r, $sc, '');
        }

        add_key(\@r, 'SC036', 'Shift', 2.75);

        push @rows, \@r;
    }

    # --------------------------------------------------------
    # Spacebar row
    # --------------------------------------------------------

    {
        my @r;

        add_key(\@r, 'SC01D', 'Ctrl', 1.25);
        add_key(\@r, 'SC15B', 'Win', 1.25);
        add_key(\@r, 'SC038', 'Alt', 1.25);
        add_key(\@r, 'SC039', 'Space', 6.25);
        add_key(\@r, 'SC138', 'AltGr', 1.25);
        add_key(\@r, 'SC15C', 'Win', 1.25);
        add_key(\@r, 'SC15D', 'Menu', 1.25);
        add_key(\@r, 'SC11D', 'Ctrl', 1.25);

        push @rows, \@r;
    }

    return @rows;
}

# ------------------------------------------------------------
# Extended ANSI 104 / ISO 105 geometry
# ------------------------------------------------------------

sub build_fullsize {

    my ($iso) = @_;

    my @rows;

    # --------------------------------------------------------
    # Function row
    # --------------------------------------------------------

    {
        my @r;

        add_key(\@r, 'SC001', 'Esc');

        gap(\@r, 1);

        add_key(\@r, 'SC03B', 'F1');
        add_key(\@r, 'SC03C', 'F2');
        add_key(\@r, 'SC03D', 'F3');
        add_key(\@r, 'SC03E', 'F4');

        gap(\@r, 0.5);

        add_key(\@r, 'SC03F', 'F5');
        add_key(\@r, 'SC040', 'F6');
        add_key(\@r, 'SC041', 'F7');
        add_key(\@r, 'SC042', 'F8');

        gap(\@r, 0.5);

        add_key(\@r, 'SC043', 'F9');
        add_key(\@r, 'SC044', 'F10');
        add_key(\@r, 'SC057', 'F11');
        add_key(\@r, 'SC058', 'F12');

        push @rows, \@r;
    }

    # --------------------------------------------------------
    # Number row + navigation + numeric keypad
    # --------------------------------------------------------

    {
        my @r;

        add_key(\@r, 'SC029', '`');

        for my $sc (qw(
            SC002 SC003 SC004 SC005 SC006 SC007
            SC008 SC009 SC00A SC00B SC00C SC00D
        )) {
            add_key(\@r, $sc, '');
        }

        add_key(\@r, 'SC00E', 'Backspace', 2);

        gap(\@r, 0.75);

        add_key(\@r, 'SC137', 'PrtSc');
        add_key(\@r, 'SC046', 'ScrLk');
        add_key(\@r, 'SC045', 'Pause');

        gap(\@r, 0.5);

        add_key(\@r, 'SC045', 'Num');
        add_key(\@r, 'SC135', '/');
        add_key(\@r, 'SC037', '*');
        add_key(\@r, 'SC04A', '-');

        push @rows, \@r;
    }

    # --------------------------------------------------------
    # QWERTY row + navigation + numeric keypad
    # --------------------------------------------------------

    {
        my @r;

        add_key(\@r, 'SC00F', 'Tab', 1.5);

        for my $sc (qw(
            SC010 SC011 SC012 SC013 SC014 SC015
            SC016 SC017 SC018 SC019 SC01A SC01B
        )) {
            add_key(\@r, $sc, '');
        }

        if ($iso) {
            add_iso_enter(\@r, 'SC01C', 'Enter');
        }
        else {
            add_key(\@r, 'SC02B', '\\', 1.5);
        }

        gap(\@r, 0.75);

        add_key(\@r, 'SC152', 'Ins');
        add_key(\@r, 'SC147', 'Home');
        add_key(\@r, 'SC149', 'PgUp');

        gap(\@r, 0.5);

        add_key(\@r, 'SC047', '7');
        add_key(\@r, 'SC048', '8');
        add_key(\@r, 'SC049', '9');
        add_key(\@r, 'SC04E', '+', 1, 2);

        push @rows, \@r;
    }

    # --------------------------------------------------------
    # Home row + navigation + numeric keypad
    # --------------------------------------------------------

    {
        my @r;

        add_key(\@r, 'SC03A', 'Caps', 1.75);

        for my $sc (qw(
            SC01E SC01F SC020 SC021 SC022
            SC023 SC024 SC025 SC026 SC027 SC028
        )) {
            add_key(\@r, $sc, '');
        }

        if ($iso) {
            add_key(\@r, 'SC02B', '\\');
            gap(\@r, 2);
        }
        else {
            add_key(\@r, 'SC01C', 'Enter', 2.25);
            gap(\@r, 0.75);
        }

        add_key(\@r, 'SC153', 'Del');
        add_key(\@r, 'SC14F', 'End');
        add_key(\@r, 'SC151', 'PgDn');

        gap(\@r, 0.5);

        add_key(\@r, 'SC04B', '4');
        add_key(\@r, 'SC04C', '5');
        add_key(\@r, 'SC04D', '6');

        push @rows, \@r;
    }

    # --------------------------------------------------------
    # Bottom letter row + arrow cluster + numeric keypad
    # --------------------------------------------------------

    {
        my @r;

        add_key(\@r, 'SC02A', 'Shift', $iso ? 1.25 : 2.25);

        if ($iso) {
            add_key(\@r, 'SC056', '\\');
        }

        for my $sc (qw(
            SC02C SC02D SC02E SC02F SC030
            SC031 SC032 SC033 SC034 SC035
        )) {
            add_key(\@r, $sc, '');
        }

        add_key(\@r, 'SC036', 'Shift', 2.75);

        gap(\@r, 1.75);

        add_key(\@r, 'SC148', '↑');

        gap(\@r, 1.5);

        add_key(\@r, 'SC04F', '1');
        add_key(\@r, 'SC050', '2');
        add_key(\@r, 'SC051', '3');
        add_key(\@r, 'SC11C', 'Enter', 1, 2);

        push @rows, \@r;
    }

    # --------------------------------------------------------
    # Spacebar row
    # --------------------------------------------------------

    {
        my @r;

        add_key(\@r, 'SC01D', 'Ctrl', 1.25);
        add_key(\@r, 'SC15B', 'Win', 1.25);
        add_key(\@r, 'SC038', 'Alt', 1.25);
        add_key(\@r, 'SC039', 'Space', 6.25);
        add_key(\@r, 'SC138', 'AltGr', 1.25);
        add_key(\@r, 'SC15C', 'Win', 1.25);
        add_key(\@r, 'SC15D', 'Menu', 1.25);
        add_key(\@r, 'SC11D', 'Ctrl', 1.25);

        gap(\@r, 0.75);

        add_key(\@r, 'SC14B', '←');
        add_key(\@r, 'SC150', '↓');
        add_key(\@r, 'SC14D', '→');

        gap(\@r, 0.5);

        add_key(\@r, 'SC052', '0', 2);
        add_key(\@r, 'SC053', '.');

        push @rows, \@r;
    }

    return @rows;
}

# ------------------------------------------------------------
# Keycool 84 geometry
# ------------------------------------------------------------

sub build_cool {

    my @rows;

    # --------------------------------------------------------
    # Function row
    # --------------------------------------------------------

    {
        my @r;

        align(\@r, 6);

        add_key(\@r, 'SC001', 'Esc');

        for my $sc (qw(
            SC03B SC03C SC03D SC03E
            SC03F SC040 SC041 SC042
            SC043 SC044 SC057 SC058
        )) {
            my $fallback = {
                SC03B => 'F1',  SC03C => 'F2',
                SC03D => 'F3',  SC03E => 'F4',
                SC03F => 'F5',  SC040 => 'F6',
                SC041 => 'F7',  SC042 => 'F8',
                SC043 => 'F9',  SC044 => 'F10',
                SC057 => 'F11', SC058 => 'F12',
            }->{$sc};

            add_key(\@r, $sc, $fallback);
        }

        align(\@r, 5);

        add_fixed_key(\@r, "PrtSc\nNmLk");
        add_fixed_key(\@r, "Pause\nScrLk");
        add_fixed_key(\@r, "Delete\nInsert");

        push @rows, \@r;
    }

    # --------------------------------------------------------
    # Number row
    # --------------------------------------------------------

    {
        my @r;

        align(\@r, 4);

        add_key(\@r, 'SC029', '~`');

        for my $sc (qw(
            SC002 SC003 SC004 SC005 SC006 SC007
            SC008 SC009 SC00A SC00B SC00C SC00D
        )) {
            add_key(\@r, $sc, '');
        }

        align(\@r, 6);

        add_key(\@r, 'SC00E', 'Backspace', 2);
        add_fixed_key(\@r, 'Home');

        push @rows, \@r;
    }

    # --------------------------------------------------------
    # QWERTY row
    # --------------------------------------------------------

    {
        my @r;

        align(\@r, 4);

        add_key(\@r, 'SC00F', 'Tab', 1.5);

        for my $sc (qw(
            SC010 SC011 SC012 SC013 SC014 SC015
            SC016 SC017 SC018 SC019 SC01A SC01B
        )) {
            add_key(\@r, $sc, '');
        }

        add_key(\@r, 'SC02B', '|\\', 1.5);

        align(\@r, 6);

        add_fixed_key(\@r, 'Page Up');

        push @rows, \@r;
    }

    # --------------------------------------------------------
    # Home row
    # --------------------------------------------------------

    {
        my @r;

        align(\@r, 4);

        add_key(\@r, 'SC03A', 'Caps Lock', 1.75);

        for my $sc (qw(
            SC01E SC01F SC020 SC021 SC022
            SC023 SC024 SC025 SC026 SC027 SC028
        )) {
            add_key(\@r, $sc, '');
        }

        align(\@r, 6);

        add_key(\@r, 'SC01C', 'Enter', 2.25);
        add_fixed_key(\@r, 'Page Down');

        push @rows, \@r;
    }

    # --------------------------------------------------------
    # Bottom letter row
    # --------------------------------------------------------

    {
        my @r;

        add_key(\@r, 'SC02A', 'Shift', 2.25);

        align(\@r, 4);

        for my $sc (qw(
            SC02C SC02D SC02E SC02F SC030
            SC031 SC032 SC033 SC034 SC035
        )) {
            add_key(\@r, $sc, '');
        }

        align(\@r, 6);

        add_key(\@r, 'SC036', 'Shift', 1.75);

        align(\@r, 7);

        add_fixed_key(\@r, '↑');

        align(\@r, 6);

        add_fixed_key(\@r, 'End');

        push @rows, \@r;
    }

    # --------------------------------------------------------
    # Spacebar row
    # --------------------------------------------------------

    {
        my @r;

        add_fixed_key(\@r, 'Ctrl', 1.25);
        add_fixed_key(\@r, 'Win', 1.25);
        add_fixed_key(\@r, 'Alt', 1.25);

        align(\@r, 7);

        add_key(\@r, 'SC039', '', 6.25);

        align(\@r, 6);

        add_fixed_key(\@r, 'Alt');
        add_fixed_key(\@r, 'Fn');
        add_fixed_key(\@r, 'Ctrl');

        align(\@r, 7);

        add_fixed_key(\@r, '←');
        add_fixed_key(\@r, '↓');
        add_fixed_key(\@r, '→');

        push @rows, \@r;
    }

    return @rows;
}

# ------------------------------------------------------------
# Select keyboard geometry
# ------------------------------------------------------------

my @rows;

if ($keyboard eq 'compact') {
    @rows = build_compact_ansi();
}
elsif ($keyboard eq 'cool') {
    @rows = build_cool();
}
elsif ($keyboard eq 'iso') {
    @rows = build_fullsize(1);
}
else {
    @rows = build_fullsize(0);
}

# ------------------------------------------------------------
# Generate notes
# ------------------------------------------------------------

my @notes;

push @notes, "$keyboard_name{$keyboard} keyboard";

for my $dk (sort keys %deadkeys) {

    my $count = scalar keys %{$deadkeys{$dk}};

    push @notes, "$dk ($count mappings)";
}

# ------------------------------------------------------------
# Generate KLE JSON
# ------------------------------------------------------------

my $kle = [
    {
        name  => $layoutname,
        notes => join('; ', @notes),
    },
    @rows,
];

my $json = JSON::PP->new
    ->utf8(0)
    ->pretty
    ->canonical
    ->encode($kle);

if (defined $output) {

    open my $out, '>:encoding(UTF-8)', $output
        or die "Cannot create $output: $!\n";

    print {$out} $json;
    close $out;

}
else {
    print $json;
}
