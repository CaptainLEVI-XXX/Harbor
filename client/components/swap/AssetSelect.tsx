'use client';

import * as Select from '@radix-ui/react-select';
import TokenMark from '@/components/TokenMark';
import type { Asset } from '@/lib/swap/types';

type Props = {
  label: string;
  value: string;
  options: Asset[];
  onChange: (symbol: string) => void;
};

/**
 * Radix supplies the behaviour - roving focus, typeahead, escape, the popper.
 * Every visual is ours: a raised tile in the same material as the modal.
 *
 * This is a real control from the first build even while only one pair exists.
 * A label that later grows a menu teaches people the wrong shape twice.
 */
export default function AssetSelect({ label, value, options, onChange }: Props) {
  return (
    <Select.Root value={value} onValueChange={onChange}>
      <Select.Trigger className="asset" aria-label={label}>
        <TokenMark symbol={value} chain />
        <Select.Value />
        <Select.Icon className="caret">▾</Select.Icon>
      </Select.Trigger>

      <Select.Portal>
        <Select.Content className="assetmenu" position="popper" sideOffset={8} align="end">
          <Select.Viewport>
            {options.map(asset => (
              <Select.Item key={asset.symbol} value={asset.symbol} className="assetitem">
                <TokenMark symbol={asset.symbol} />
                <span>
                  <Select.ItemText>{asset.symbol}</Select.ItemText>
                  <small>{asset.name}</small>
                </span>
              </Select.Item>
            ))}
          </Select.Viewport>
        </Select.Content>
      </Select.Portal>
    </Select.Root>
  );
}
