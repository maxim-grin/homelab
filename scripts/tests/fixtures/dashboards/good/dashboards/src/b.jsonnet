local panel = import 'panel.libsonnet';

{
  uid: 'fixture-b',
  title: 'Fixture b',
  panels: [panel.stat('Up')],
}
