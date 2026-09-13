import { render,screen,fireEvent,within } from '@testing-library/react';
import { describe,it,expect } from 'vitest';
import dataset from '@/data/analytics/benchmark.json';
import { parseBenchmark } from '@/lib/analytics/schema';
import AnalyticsDashboard from '../AnalyticsDashboard';
const data=parseBenchmark(dataset);
describe('Analytics page',()=>{
 it('shows four charts and distinguishes simulations from live indexing',()=>{
  const {container}=render(<AnalyticsDashboard data={data}/>);
  expect(container.querySelectorAll('[data-plot]')).toHaveLength(4);
  expect(container.querySelectorAll('.axis-title')).toHaveLength(8);
  expect(screen.getByText('Historical simulation')).toBeInTheDocument();
  expect(screen.getByText('Reconciled research data · Graph indexing pending')).toBeInTheDocument();
  expect(screen.queryByText('Harbor + FACE')).not.toBeInTheDocument();
 });
 it('toggles chart series and keeps the shared valuation when Harbor is hidden',()=>{
  const {container}=render(<AnalyticsDashboard data={data}/>);
  const legend=screen.getByRole('group',{name:'Pricing mechanisms'});
  fireEvent.click(within(legend).getByRole('button',{name:'Harbor'}));
  expect(container.querySelector('[data-plot="profit"] [data-series="harbor"]')).toBeNull();
  expect(container.querySelector('[data-plot="accuracy"] [data-series="queue_aware"]')).not.toBeNull();
  expect(screen.getByRole('status')).toHaveTextContent('Queue-aware valuation');
 });
 it('cannot hide the last model and keeps evidence available without hover',()=>{
  render(<AnalyticsDashboard data={data}/>);
  const legend=screen.getByRole('group',{name:'Pricing mechanisms'});
  for(const name of ['Fixed-delay pricing','Age-based pricing','Queue-aware valuation','Harbor'])fireEvent.click(within(legend).getByRole('button',{name}));
  expect(within(legend).getByRole('button',{name:'Harbor'})).toHaveAttribute('aria-pressed','true');
  expect(screen.getByRole('table',{hidden:true})).toBeInTheDocument();
 });
});
