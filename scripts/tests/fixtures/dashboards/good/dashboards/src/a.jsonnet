local panel = import 'panel.libsonnet';

{
  uid: 'fixture-a',
  title: 'Fixture a',
  panels: [panel.stat('Up')],
}
