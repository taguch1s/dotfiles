param([ValidateSet('start','status','serve','revoke','resume','library')][string]$Command = 'status')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$script:Root = Join-Path $env:LOCALAPPDATA 'AgentBrowser\TradingView'
$script:Revoked = Join-Path $script:Root 'revoked'
$script:Audit = Join-Path $script:Root 'audit.jsonl'

function Test-ChartUrl([string]$Url) {
    # URL 正規化で許可 authority を拡張しない。
    if ($Url -cnotmatch '^https://(jp|www)\.tradingview\.com(?::443)?/chart/[A-Za-z0-9_/-]*(?:[?#].*)?$') { return $false }
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return $false }
    return $u.Scheme -ceq 'https' -and $u.Port -eq 443 -and $u.UserInfo -eq '' -and
        @('jp.tradingview.com','www.tradingview.com') -ccontains $u.Host -and $u.AbsolutePath.StartsWith('/chart/')
}
function Get-Action([string]$Action) {
    # 任意 selector や JavaScript を受け取る経路を作らない。
    switch -CaseSensitive ($Action) {
        'chart_style_open' {
            return "const active=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent.trim()==='Loop IFD fixed grid (TV1)'&&e.querySelector('[class*=activeStrategy]'));if(active.length!==1)throw Error('unique active TV1 unavailable');const buttons=Array.from(document.querySelectorAll('button[aria-label]')).filter(e=>e.getClientRects().length&&!e.closest('.monaco-editor,[data-name=pine-editor-dialog]')&&['ローソク足','平均足','Candles','Heikin Ashi'].includes(e.getAttribute('aria-label'))).filter(e=>{const r=e.getBoundingClientRect();if(r.width<=0||r.height<=0||r.x<0||r.y<0||r.right>innerWidth||r.bottom>innerHeight)return false;const hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);return hit&&(e===hit||e.contains(hit))});if(buttons.length!==1)throw Error('unique unobscured chart style button unavailable');buttons[0].click();return {requested:'chart style menu',qa:buttons[0].getAttribute('data-qa-id')};"
        }
        'chart_style_candidates_read' {
            return "return {candidates:Array.from(document.querySelectorAll('button[aria-label]')).filter(e=>e.getClientRects().length&&!e.closest('.monaco-editor,[data-name=pine-editor-dialog]')&&['ローソク足','平均足','Candles','Heikin Ashi'].includes(e.getAttribute('aria-label'))).slice(0,10).map(e=>{const r=e.getBoundingClientRect();const inViewport=r.width>0&&r.height>0&&r.x>=0&&r.y>=0&&r.right<=innerWidth&&r.bottom<=innerHeight;const hit=inViewport?document.elementFromPoint(r.x+r.width/2,r.y+r.height/2):null;return {aria:e.getAttribute('aria-label'),qa:e.getAttribute('data-qa-id'),inViewport,ownedHit:!!hit&&(e===hit||e.contains(hit)),rect:{x:r.x,y:r.y,width:r.width,height:r.height}}})};"
        }
        'report_period_menu_open' {
            return "const bars=Array.from(document.querySelectorAll('[data-qa-id=backtesting-report-toolbar]')).filter(e=>e.getClientRects().length);if(bars.length!==1)throw Error('unique Report toolbar unavailable');const panel=bars[0].closest('.layout__area--bottom');if(!panel||!panel.innerText.includes('Loop IFD fixed grid (TV1)'))throw Error('TV1 Report unavailable');const buttons=Array.from(panel.querySelectorAll('[data-qa-id=date-range-menu]')).filter(e=>e.getClientRects().length);if(buttons.length!==1)throw Error('unique Report period button unavailable');buttons[0].click();return {requested:'Report period menu'};"
        }
        { @('chart_style_choices_read','report_period_choices_read') -ccontains $_ } {
            if ($Action -ceq 'chart_style_choices_read') {
                return "const active=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent.trim()==='Loop IFD fixed grid (TV1)'&&e.querySelector('[class*=activeStrategy]'));if(active.length!==1)throw Error('unique active TV1 unavailable');const items=Array.from(document.querySelectorAll('[data-qa-id=chart-style-menu-item]')).filter(e=>e.getClientRects().length&&!e.closest('.monaco-editor,[data-name=pine-editor-dialog]'));if(items.length<2||items.length>30)throw Error('chart style menu items unavailable or ambiguous');return {choices:items.map(e=>({qa:e.getAttribute('data-qa-id'),text:e.textContent.trim().slice(0,100),disabled:e.disabled===true||e.getAttribute('aria-disabled')==='true'||e.getAttribute('data-disabled')==='true'}))};"
            }
            $pattern=if($Action -ceq 'chart_style_choices_read'){'ローソク|平均足|Candles|Heikin'}else{'Deep|ディープ|深い|バックテスト|Backtesting|期間|Date range'}
            return "const scopes=Array.from(document.querySelectorAll('[role=menu],[role=listbox],[role=dialog],[data-name=popup-menu-container]')).filter(e=>e.getClientRects().length&&!e.closest('.monaco-editor')&&/$pattern/i.test(e.textContent));const roots=scopes.filter(e=>!scopes.some(p=>p!==e&&p.contains(e)));if(roots.length!==1)throw Error('unique fixed choices scope unavailable');const scope=roots[0];return {scope:{qa:scope.getAttribute('data-qa-id'),name:scope.getAttribute('data-name'),role:scope.getAttribute('role')},text:scope.innerText.slice(0,1800),choices:Array.from(scope.querySelectorAll('button,[role=menuitem],[role=option],[role=combobox],[data-is-popover-item-button=true],span')).filter(e=>e.getClientRects().length&&e.textContent.trim().length<=100).slice(0,40).map(e=>({tag:e.tagName,qa:e.getAttribute('data-qa-id'),name:e.getAttribute('data-name'),role:e.getAttribute('role'),aria:e.getAttribute('aria-label'),title:e.getAttribute('title'),text:e.textContent.trim(),disabled:e.disabled===true||e.getAttribute('aria-disabled')==='true'}))};"
        }
        { @('chart_style_heikin_select','chart_style_candles_select') -ccontains $_ } {
            $labels=if($Action -ceq 'chart_style_heikin_select'){"['平均足','Heikin Ashi']"}else{"['ローソク足','Candles']"}
            return "const active=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent.trim()==='Loop IFD fixed grid (TV1)'&&e.querySelector('[class*=activeStrategy]'));if(active.length!==1)throw Error('unique active TV1 unavailable');const items=Array.from(document.querySelectorAll('[data-qa-id=chart-style-menu-item]')).filter(e=>e.getClientRects().length&&!e.closest('.monaco-editor,[data-name=pine-editor-dialog]'));if(items.length<2||items.length>30)throw Error('chart style menu items unavailable or ambiguous');const labels=$labels;const choices=items.filter(e=>labels.includes(e.textContent.trim()));if(choices.length!==1)throw Error('unique fixed chart style choice unavailable');const choice=choices[0];if(choice.disabled===true||choice.getAttribute('aria-disabled')==='true'||choice.getAttribute('data-disabled')==='true')throw Error('fixed chart style choice disabled');choice.click();return {requested:choice.textContent.trim(),verification:'read back chart style and runtime result before evidence'};"
        }
        'test_remaining_controls_read' {
            return "const visible=e=>e.getClientRects().length>0;const excluded=e=>e.closest('.monaco-editor,[data-name*=account],[data-qa-id*=account]');const meta=e=>{const r=e.getBoundingClientRect();return {tag:e.tagName,qa:e.getAttribute('data-qa-id'),name:e.getAttribute('data-name'),role:e.getAttribute('role'),aria:e.getAttribute('aria-label'),title:e.getAttribute('title'),tooltip:e.getAttribute('data-tooltip'),text:e.textContent.trim().slice(0,80),disabled:e.disabled===true||e.getAttribute('aria-disabled')==='true',rect:{x:r.x,y:r.y,width:r.width,height:r.height}}};const controls=Array.from(document.querySelectorAll('button,[role=button],[role=combobox]')).filter(e=>visible(e)&&!excluded(e));const chartStyle=controls.filter(e=>/style|ローソク|平均足|バー|chart.type/i.test([e.getAttribute('data-name'),e.getAttribute('data-qa-id'),e.getAttribute('aria-label'),e.getAttribute('title'),e.getAttribute('data-tooltip')].join(' '))).slice(0,25).map(meta);const toolbars=Array.from(document.querySelectorAll('[data-qa-id=backtesting-report-toolbar]')).filter(visible);if(toolbars.length!==1)throw Error('unique Report toolbar unavailable');const panel=toolbars[0].closest('.layout__area--bottom');if(!panel||!panel.innerText.includes('Loop IFD fixed grid (TV1)'))throw Error('TV1 Report unavailable');const reportHeader=Array.from(panel.querySelectorAll('button,[role=button],[role=combobox]')).filter(e=>visible(e)&&!excluded(e)&&!e.closest('table,[role=table],[role=grid]')).slice(0,40).map(meta);const planLabels=['Basic','Essential','Plus','Premium','Ultimate','ベーシック','エッセンシャル','プラス','プレミアム','アルティメット'];const plans=Array.from(document.querySelectorAll('span,div,button')).filter(e=>visible(e)&&!excluded(e)&&e.children.length===0&&planLabels.includes(e.textContent.trim())).slice(0,10).map(meta);return {chartStyle,reportHeader,plans};"
        }
        'test_observer_capture' {
            $body=Get-Action 'test_summary_capture'
            return $body.Replace('Math.min(550,r.width)','Math.min(950,r.width)').Replace('Math.min(450,r.height)','Math.min(350,r.height)').Replace('const sx=(r.width-width)*layer.width/r.width;','const sx=0;').Replace('ctx.drawImage(layer,sx,0,sw,sh,0,0,width,height);','ctx.drawImage(layer,sx,(r.height-height)*layer.height/r.height,sw,sh,0,0,width,height);').Replace('clip:{x:r.right-width,y:r.y,width,height}','clip:{x:r.x,y:r.bottom-height,width,height}')
        }
        'test_viewport_wide' { return "return {width:1440,height:1000,deviceScaleFactor:1,mobile:false};" }
        { @('properties_margin_long_single','properties_margin_long_multi','properties_margin_short_single','properties_margin_short_multi','properties_margin_long_single_adjusted','properties_margin_long_full_single','properties_margin_long_full_multi','properties_margin_short_full_single','properties_margin_short_full_multi','properties_margin_long_full_final','properties_margin_short_partial_single_final','properties_margin_short_partial_multi_final') -ccontains $_ } {
            $values=switch -CaseSensitive ($Action) {
                'properties_margin_long_single' { @(78700,2,1) }
                'properties_margin_long_multi' { @(157400,2,1) }
                'properties_margin_short_single' { @(157400,1,1) }
                'properties_margin_short_multi' { @(314800,1,1) }
                'properties_margin_long_single_adjusted' { @(78750,2,1) }
                'properties_margin_long_full_single' { @(200,1000,1) }
                'properties_margin_long_full_multi' { @(320,1000,1) }
                'properties_margin_short_full_single' { @(200,1,1000) }
                'properties_margin_short_full_multi' { @(320,1,1000) }
                'properties_margin_long_full_final' { @(160,1000,1) }
                'properties_margin_short_partial_single_final' { @(157500,1,1) }
                'properties_margin_short_partial_multi_final' { @(314900,1,1) }
            }
            $json=$values | ConvertTo-Json -Compress
            return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1)throw Error('unique TV1 Properties unavailable');const d=dialogs[0];const names=['initial-capital-input','long-leverage-input','short-leverage-input'];const inputs=names.map(name=>Array.from(d.querySelectorAll('input')).filter(e=>(e.getAttribute('data-qa-id')||'').split(/\s+/).includes(name)&&e.getClientRects().length));if(inputs.some(a=>a.length!==1))throw Error('margin Properties schema mismatch');const values=$json;for(let i=0;i<3;i++){const e=inputs[i][0];e.focus();Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,String(values[i]));e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));e.blur();}return {case:'$Action',requested:values,readback:inputs.map(a=>a[0].value)};"
        }
        'settings_detail_choices_inspect' { return "const boxes=Array.from(document.querySelectorAll('[role=listbox]')).filter(e=>e.getClientRects().length&&e.textContent.includes('デフォルト（バーあたり4ティック）')&&e.textContent.includes('高（バーあたり約40ティック）'));if(boxes.length!==1)throw Error('unique bar detail listbox unavailable');return {choices:Array.from(boxes[0].querySelectorAll('span,div,button')).filter(e=>e.children.length===0&&e.getClientRects().length&&['デフォルト（バーあたり4ティック）','高（バーあたり約40ティック）'].includes(e.textContent.trim())).map(e=>{const ancestors=[];for(let p=e.parentElement,i=0;p&&i<6&&p!==boxes[0].parentElement;p=p.parentElement,i++)ancestors.push({tag:p.tagName,role:p.getAttribute('role'),qa:p.getAttribute('data-qa-id'),name:p.getAttribute('data-name'),disabled:p.getAttribute('data-disabled'),nativeDisabled:p.disabled===true,ariaDisabled:p.getAttribute('aria-disabled'),title:p.getAttribute('title'),outerHTML:p.outerHTML.slice(0,2000)});return {label:e.textContent.trim(),outerHTML:e.outerHTML.slice(0,2000),ancestors}})};" }
        { @('properties_detail_high_select','properties_detail_default_select') -ccontains $_ } {
            $label=if ($Action -ceq 'properties_detail_high_select') { '高（バーあたり約40ティック）' } else { 'デフォルト（バーあたり4ティック）' }
            return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)')&&e.querySelector('input[data-qa-id~=initial-capital-input]'));if(dialogs.length!==1)throw Error('unique TV1 Properties unavailable');const boxes=Array.from(document.querySelectorAll('[role=listbox]')).filter(e=>e.getClientRects().length&&e.textContent.includes('デフォルト（バーあたり4ティック）')&&e.textContent.includes('高（バーあたり約40ティック）'));if(boxes.length!==1)throw Error('unique bar detail listbox unavailable');const choices=Array.from(boxes[0].querySelectorAll('span,div,button')).filter(e=>e.getClientRects().length&&e.children.length===0&&e.textContent.trim()==='$label');if(choices.length!==1)throw Error('unique fixed bar detail choice unavailable');const choice=choices[0].closest('[data-is-popover-item-button=true]');if(!choice||!boxes[0].contains(choice)||choice.getAttribute('aria-disabled')==='true'||choice.getAttribute('data-disabled')==='true'||choice.disabled===true)throw Error('bar detail choice unavailable or disabled');for(const type of ['pointerdown','mousedown','pointerup','mouseup','click']){const buttons=type.endsWith('down')?1:0;const options={bubbles:true,cancelable:true,button:0,buttons,pointerId:1,pointerType:'mouse',isPrimary:true};choice.dispatchEvent(type.startsWith('pointer')?new PointerEvent(type,options):new MouseEvent(type,options));}return new Promise(resolve=>setTimeout(()=>{const readback=Array.from(dialogs[0].querySelectorAll('[data-qa-id~=bar-detalization-input]')).map(e=>e.textContent.trim());resolve({requested:'$label',adopted:readback.length===1&&readback[0]==='$label',readback});},100));"
        }
        { @('properties_pyramiding_1','properties_pyramiding_320') -ccontains $_ } {
            $value=if ($Action -ceq 'properties_pyramiding_1') { 1 } else { 320 }
            return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1)throw Error('unique TV1 dialog unavailable');const inputs=Array.from(dialogs[0].querySelectorAll('input[data-qa-id~=pyramiding-input]')).filter(e=>e.getClientRects().length);if(inputs.length!==1)throw Error('unique pyramiding field unavailable');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(inputs[0],'$value');inputs[0].dispatchEvent(new Event('input',{bubbles:true}));inputs[0].dispatchEvent(new Event('change',{bubbles:true}));return {pyramiding:$value,readback:inputs[0].value};"
        }
        'test_pine_console_open' { return "const editors=Array.from(document.querySelectorAll('.monaco-editor.pine-editor-monaco[role=code]')).filter(e=>e.getClientRects().length);if(editors.length!==1)throw Error('unique Pine editor unavailable');let panel=null;for(let p=editors[0].parentElement,i=0;p&&i<8&&p.tagName!=='BODY'&&p.tagName!=='MAIN';p=p.parentElement,i++){if(/pine-editor-dialog|pane-editor-dialog/.test([p.getAttribute('data-qa-id'),p.getAttribute('data-name'),p.className].join(' '))){panel=p;break;}}if(!panel)throw Error('Pine panel unavailable');const buttons=Array.from(panel.querySelectorAll('button[data-tooltip=\u0022コンソールを開く\u0022]')).filter(e=>e.getClientRects().length);if(buttons.length!==1)throw Error('unique Pine console toggle unavailable');if(buttons[0].getAttribute('data-active')!=='true')buttons[0].click();return new Promise(resolve=>setTimeout(()=>resolve({active:buttons[0].getAttribute('data-active'),tabs:Array.from(panel.querySelectorAll('[role=tab]')).filter(e=>e.getClientRects().length&&!e.closest('.monaco-editor')).slice(0,15).map(e=>({text:e.textContent.trim().slice(0,120),qa:e.getAttribute('data-qa-id'),name:e.getAttribute('data-name'),selected:e.getAttribute('aria-selected')})),containers:Array.from(panel.querySelectorAll('[class*=console],[data-name*=console],[data-qa-id*=console]')).filter(e=>e.getClientRects().length&&!e.closest('.monaco-editor')&&!e.querySelector('.monaco-editor')).slice(0,15).map(e=>({tag:e.tagName,classes:e.className,name:e.getAttribute('data-name'),qa:e.getAttribute('data-qa-id'),text:e.textContent.trim().slice(0,2000)}))}),150));" }
        'test_pine_footer_inspect' { return "const editors=Array.from(document.querySelectorAll('.monaco-editor.pine-editor-monaco[role=code]')).filter(e=>e.getClientRects().length);if(editors.length!==1)throw Error('unique Pine editor unavailable');let panel=null;for(let p=editors[0].parentElement,i=0;p&&i<8&&p.tagName!=='BODY'&&p.tagName!=='MAIN';p=p.parentElement,i++){if(/pine-editor-dialog|pane-editor-dialog/.test([p.getAttribute('data-qa-id'),p.getAttribute('data-name'),p.className].join(' '))){panel=p;break;}}if(!panel)throw Error('Pine panel unavailable');const panelRect=panel.getBoundingClientRect();const buttons=Array.from(panel.querySelectorAll('button')).filter(e=>{const r=e.getBoundingClientRect();return e.getClientRects().length&&r.x<panelRect.x+100&&r.y>panelRect.bottom-50});return {buttons:buttons.slice(0,5).map(e=>{const ancestors=[];for(let p=e.parentElement,i=0;p&&i<3&&p!==panel.parentElement;p=p.parentElement,i++)ancestors.push({tag:p.tagName,qa:p.getAttribute('data-qa-id'),name:p.getAttribute('data-name'),classes:p.className,title:p.getAttribute('title'),aria:p.getAttribute('aria-label')});const r=e.getBoundingClientRect();return {outerHTML:e.outerHTML.slice(0,2500),rect:{x:r.x,y:r.y,width:r.width,height:r.height},svgTitles:Array.from(e.querySelectorAll('svg title')).map(t=>t.textContent.slice(0,100)),ancestors}})};" }
        'test_editor_more_native' { return "const editors=Array.from(document.querySelectorAll('.monaco-editor.pine-editor-monaco[role=code]')).filter(e=>e.getClientRects().length);if(editors.length!==1)throw Error('unique Pine editor unavailable');let panel=null;for(let p=editors[0].parentElement,i=0;p&&i<8&&p.tagName!=='BODY'&&p.tagName!=='MAIN';p=p.parentElement,i++){if(/pine-editor-dialog|pane-editor-dialog/.test([p.getAttribute('data-qa-id'),p.getAttribute('data-name'),p.className].join(' '))){panel=p;break;}}if(!panel)throw Error('Pine panel unavailable');const buttons=Array.from(panel.querySelectorAll('button[data-qa-id=script-more-options]')).filter(e=>e.getClientRects().length);if(buttons.length!==1)throw Error('unique Pine More unavailable');const r=buttons[0].getBoundingClientRect();if(r.x<0||r.y<0||r.right>innerWidth||r.bottom>innerHeight)throw Error('Pine More bounds unavailable');const hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);return {x:r.x+r.width/2,y:r.y+r.height/2,ownedHit:hit===buttons[0]||buttons[0].contains(hit),tag:hit?.tagName,qa:hit?.getAttribute('data-qa-id'),title:hit?.getAttribute('title')};" }
        'test_editor_more_open' { return "const editors=Array.from(document.querySelectorAll('.monaco-editor.pine-editor-monaco[role=code]')).filter(e=>e.getClientRects().length);if(editors.length!==1)throw Error('unique Pine editor unavailable');let panel=null;for(let p=editors[0].parentElement,i=0;p&&i<8&&p.tagName!=='BODY'&&p.tagName!=='MAIN';p=p.parentElement,i++){if(/pine-editor-dialog|pane-editor-dialog/.test([p.getAttribute('data-qa-id'),p.getAttribute('data-name'),p.className].join(' '))){panel=p;break;}}if(!panel)throw Error('Pine panel unavailable');const buttons=Array.from(panel.querySelectorAll('button[data-qa-id=script-more-options]')).filter(e=>e.getClientRects().length&&e.getAttribute('title')==='その他');if(buttons.length!==1)throw Error('unique Pine More unavailable');const r=buttons[0].getBoundingClientRect();const hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);if(hit!==buttons[0]&&!buttons[0].contains(hit))throw Error('Pine More occluded');buttons[0].click();return {opened:true};" }
        'test_pine_panel_inventory' { return "const editors=Array.from(document.querySelectorAll('.monaco-editor.pine-editor-monaco[role=code]')).filter(e=>e.getClientRects().length);if(editors.length!==1)throw Error('unique visible Pine editor unavailable');const rect=e=>{const r=e.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}};const ancestors=[];let panel=null;for(let p=editors[0].parentElement,i=0;p&&i<8&&p.tagName!=='BODY'&&p.tagName!=='MAIN';p=p.parentElement,i++){const attrs={tag:p.tagName,qa:p.getAttribute('data-qa-id'),name:p.getAttribute('data-name'),classes:p.className,rect:rect(p)};ancestors.push(attrs);if(/pine-editor-dialog|pane-editor-dialog/.test([attrs.qa,attrs.name,attrs.classes].join(' '))){panel=p;break;}if(p.querySelector('[data-qa-id=pane-widget-chart-gui-wrapper]'))break;}return {editorRect:rect(editors[0]),ancestors,panelFound:!!panel,buttons:panel?Array.from(panel.querySelectorAll('button,[role=button]')).slice(0,30).map(e=>({tag:e.tagName,qa:e.getAttribute('data-qa-id'),name:e.getAttribute('data-name'),title:e.getAttribute('title'),aria:e.getAttribute('aria-label'),text:e.textContent.trim().slice(0,80),rect:rect(e),visible:!!e.getClientRects().length})):[]};" }
        'test_pine_hide' { throw 'underlying Pine toggle did not hide overlay; inspect verified panel close control first' }
        'test_source_more_native' { return "const sources=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent.trim()==='Loop IFD fixed grid (TV1)'&&e.querySelector('[class*=activeStrategy]')&&e.querySelector('[class*=openedInPineEditor]'));if(sources.length!==1)throw Error('unique owned active TV1 unavailable');const buttons=Array.from(sources[0].querySelectorAll('button[data-qa-id=legend-more-action]')).filter(e=>e.getClientRects().length);if(buttons.length!==1)throw Error('unique source More unavailable');const r=buttons[0].getBoundingClientRect();if(r.width<=0||r.height<=0||r.x<0||r.y<0||r.right>innerWidth||r.bottom>innerHeight)throw Error('source More bounds unavailable');return {x:r.x+r.width/2,y:r.y+r.height/2};" }
        'test_popup_menu_inventory' { return "return {menus:Array.from(document.querySelectorAll('[data-name*=menu],[data-qa-id*=menu],[class*=context-menu],[class*=popup-menu]')).filter(e=>e.getClientRects().length&&e.tagName!=='BODY'&&e.tagName!=='MAIN'&&!e.closest('.monaco-editor')&&!e.querySelector('.monaco-editor')&&!e.querySelector('[data-qa-id=pane-widget-chart-gui-wrapper]')).slice(0,20).map(e=>({tag:e.tagName,name:e.getAttribute('data-name'),qa:e.getAttribute('data-qa-id'),classes:e.className,text:e.textContent.trim().slice(0,2500)}))};" }
        'test_pine_logs_link_inspect' { return "const candidates=Array.from(document.querySelectorAll('div,span,button,a')).filter(e=>e.children.length===0&&e.getClientRects().length&&!e.closest('.monaco-editor')&&(/^Pine.{0,12}(Logs|ログ).{0,12}$/.test(e.textContent.trim())||['ログ','ログを表示','Logs','Show logs'].includes(e.textContent.trim())));return {links:candidates.slice(0,5).map(e=>{const ancestors=[];for(let p=e.parentElement,i=0;p&&i<3&&p.tagName!=='BODY'&&p.tagName!=='MAIN'&&!p.querySelector('.monaco-editor.pine-editor-monaco');p=p.parentElement,i++)ancestors.push({tag:p.tagName,qa:p.getAttribute('data-qa-id'),name:p.getAttribute('data-name'),classes:p.className,text:p.textContent.trim().slice(0,1000)});return {tag:e.tagName,qa:e.getAttribute('data-qa-id'),name:e.getAttribute('data-name'),classes:e.className,text:e.textContent.trim(),ancestors}})};" }
        'test_source_more_open' { return "const sources=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent.trim()==='Loop IFD fixed grid (TV1)'&&e.querySelector('[class*=activeStrategy]')&&e.querySelector('[class*=openedInPineEditor]'));if(sources.length!==1)throw Error('unique owned active TV1 unavailable');const buttons=Array.from(sources[0].querySelectorAll('button[data-qa-id=legend-more-action]'));if(buttons.length!==1)throw Error('unique source More unavailable');for(const type of ['mousedown','mouseup','click'])buttons[0].dispatchEvent(new MouseEvent(type,{bubbles:true}));return {opened:true};" }
        'test_source_menu_read' { return "return {menus:Array.from(document.querySelectorAll('[role=menu],[data-name=menu-inner]')).filter(e=>e.getClientRects().length).slice(0,5).map(e=>({text:e.innerText.slice(0,2000),items:Array.from(e.querySelectorAll('[role=menuitem],[data-role=menuitem]')).slice(0,30).map(i=>({text:i.textContent.trim().slice(0,200),qa:i.getAttribute('data-qa-id'),name:i.getAttribute('data-name'),role:i.getAttribute('role')}))})),items:Array.from(document.querySelectorAll('[role=menuitem]')).filter(e=>e.getClientRects().length).slice(0,30).map(e=>({text:e.textContent.trim().slice(0,200),qa:e.getAttribute('data-qa-id'),name:e.getAttribute('data-name')}))};" }
        'test_pine_next_problem' { return "const editors=Array.from(document.querySelectorAll('.monaco-editor.pine-editor-monaco[role=code]')).filter(e=>e.getClientRects().length);if(editors.length!==1)throw Error('unique Pine editor unavailable');const buttons=Array.from(editors[0].querySelectorAll('a[role=button]')).filter(e=>e.getClientRects().length&&(e.getAttribute('aria-label')||'').replace(/\s/g,'')==='GotoNextProblem(Error,Warning,Info)(Alt+F8)');if(buttons.length!==1)throw Error('unique Monaco next problem unavailable');buttons[0].click();return {opened:true};" }
        'test_pine_diagnostics' { return "const dialogs=Array.from(document.querySelectorAll('[data-name=pine-editor-dialog]')).filter(e=>e.getClientRects().length);const editors=Array.from(document.querySelectorAll('.monaco-editor.pine-editor-monaco[role=code]')).filter(e=>e.getClientRects().length);let root=dialogs.length===1?dialogs[0]:editors.length===1?editors[0].parentElement?.parentElement:null;if(!root)throw Error('Pine diagnostics container unavailable');return {title:document.querySelector('[data-qa-id=pine-script-title-button]')?.textContent?.trim()||null,messages:Array.from(root.querySelectorAll('.marker-widget,.markers-panel,.message,.error,[role=alert],.peekview-widget')).filter(e=>e.getClientRects().length).slice(0,20).map(e=>({classes:e.className,role:e.getAttribute('role'),text:e.textContent.trim().slice(0,3000)})),controls:Array.from(root.querySelectorAll('button,[role=button]')).filter(e=>/error|問題|エラー|console|コンソール|log|ログ/.test([e.getAttribute('title'),e.getAttribute('aria-label'),e.getAttribute('data-qa-id'),e.textContent].join(' '))).slice(0,20).map(e=>({qa:e.getAttribute('data-qa-id'),title:e.getAttribute('title'),aria:e.getAttribute('aria-label'),text:e.textContent.trim().slice(0,200)}))};" }
        'settings_direction_long_open' { return Get-Action 'settings_direction_short_open' }
        'settings_direction_long_select' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1||!Array.from(dialogs[0].querySelectorAll('[role=combobox]')).some(e=>['ロング','ショート'].includes(e.textContent.trim())))throw Error('TV1 direction dialog unavailable');const options=Array.from(document.querySelectorAll('[role=option]')).filter(e=>e.getClientRects().length&&e.textContent.trim()==='ロング');if(options.length!==1)throw Error('unique Long option unavailable');options[0].click();return {direction:'ロング'};" }
        'settings_period_custom_open' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1)throw Error('unique TV1 dialog unavailable');const combos=Array.from(dialogs[0].querySelectorAll('[role=combobox]')).filter(e=>e.getClientRects().length&&['Visible chart','Custom','カスタム'].includes(e.textContent.trim()));if(combos.length!==1)throw Error('unique period combo unavailable');combos[0].click();return {opened:true};" }
        'settings_period_custom_select' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1||!Array.from(dialogs[0].querySelectorAll('[role=combobox]')).some(e=>['Visible chart','Custom','カスタム'].includes(e.textContent.trim())))throw Error('TV1 period dialog unavailable');const options=Array.from(document.querySelectorAll('[role=option]')).filter(e=>e.getClientRects().length&&['Custom','カスタム'].includes(e.textContent.trim()));if(options.length!==1)throw Error('unique Custom option unavailable');options[0].click();return {mode:'Custom'};" }
        { @('period_aligned','period_bad_start','period_bad_end','period_pending_end','period_fifo_mid','period_reentry_end','period_margin_late','period_gap_week','period_weekend_end','period_closed_end','period_before_history','period_future') -ccontains $_ } {
            $values=Get-PeriodValues $Action | ConvertTo-Json -Compress
            return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1)throw Error('unique TV1 dialog unavailable');const d=dialogs[0];if(!Array.from(d.querySelectorAll('[role=combobox]')).some(e=>['Custom','カスタム'].includes(e.textContent.trim())))throw Error('Custom mode required');const inputs=Array.from(d.querySelectorAll('input')).filter(e=>e.getClientRects().length);if(inputs.length!==10||!d.textContent.includes('Custom開始時刻')||!d.textContent.includes('Custom終了時刻'))throw Error('period field schema mismatch');if(!/^\d{4}-\d{2}-\d{2}$/.test(inputs[0].value)||!/^\d{2}:\d{2}$/.test(inputs[1].value)||!/^\d{4}-\d{2}-\d{2}$/.test(inputs[2].value)||!/^\d{2}:\d{2}$/.test(inputs[3].value))throw Error('period field format mismatch');const values=$values;for(let i=0;i<4;i++){inputs[i].focus();Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(inputs[i],values[i]);inputs[i].dispatchEvent(new Event('input',{bubbles:true}));inputs[i].dispatchEvent(new Event('change',{bubbles:true}));inputs[i].blur();}return {case:'$Action',timezone:'UTC+09:00 verified UI',requestedValues:values,domReadback:inputs.slice(0,4).map(e=>e.value),commitVerification:'reopen settings and compare before evidence'};"
        }
        'runtime_chart_update' { return Get-Action 'bootstrap_editor_select_all' }
        'test_report_open' { return "const active=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent.trim()==='Loop IFD fixed grid (TV1)'&&e.querySelector('[class*=activeStrategy]'));if(active.length!==1)throw Error('unique active TV1 unavailable');const buttons=Array.from(document.querySelectorAll('[data-qa-id=backtesting]')).filter(e=>e.getClientRects().length&&e.getAttribute('aria-label')==='ストラテジーレポートを開く');if(buttons.length!==1)throw Error('unique Report open unavailable');buttons[0].click();return {opened:true};" }
        { @('runtime_red01','runtime_red02','runtime_red03','runtime_red04','runtime_red05','runtime_red06','runtime_observer','runtime_margin_observer','runtime_gap_observer','runtime_gap_proof_observer','runtime_gap_search_observer','runtime_canonical_restore') -ccontains $_ } { return Get-Action 'bootstrap_editor_select_all' }
        'test_pine_logs_inventory' { return "const editors=Array.from(document.querySelectorAll('.monaco-editor.pine-editor-monaco[role=code]')).filter(e=>e.getClientRects().length);if(editors.length!==1)throw Error('unique Pine editor unavailable');const ancestors=[];for(let p=editors[0].parentElement,i=0;p&&i<6&&p.tagName!=='BODY';p=p.parentElement,i++)ancestors.push({tag:p.tagName,qa:p.getAttribute('data-qa-id'),name:p.getAttribute('data-name'),className:p.className,controls:Array.from(p.querySelectorAll('button,[role=button]')).filter(e=>/log|ログ/.test([e.getAttribute('data-name'),e.getAttribute('data-qa-id'),e.getAttribute('title'),e.getAttribute('aria-label'),e.textContent].join(' '))).slice(0,20).map(e=>({tag:e.tagName,qa:e.getAttribute('data-qa-id'),name:e.getAttribute('data-name'),title:e.getAttribute('title'),aria:e.getAttribute('aria-label'),text:e.textContent.trim().slice(0,100),visible:!!e.getClientRects().length}))});return {ancestors};" }
        'properties_capital_100k' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1)throw Error('unique TV1 dialog unavailable');const inputs=Array.from(dialogs[0].querySelectorAll('input[data-qa-id~=initial-capital-input]')).filter(e=>e.getClientRects().length);if(inputs.length!==1)throw Error('unique capital field unavailable');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(inputs[0],'100000');inputs[0].dispatchEvent(new Event('input',{bubbles:true}));inputs[0].dispatchEvent(new Event('change',{bubbles:true}));return {capital:100000};" }
        'settings_bar_detail_open' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1)throw Error('unique TV1 dialog unavailable');const controls=Array.from(dialogs[0].querySelectorAll('[data-qa-id~=bar-detalization-input]')).filter(e=>e.getClientRects().length);if(controls.length!==1)throw Error('unique bar detail control unavailable');controls[0].click();return {opened:true};" }
        'test_legacy_source_hide' { return "const sources=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent.trim()==='Loop IFD fixed grid (TV1)'&&!e.querySelector('[class*=activeStrategy]')&&!e.querySelector('[class*=openedInPineEditor]'));if(sources.length!==1)throw Error('unique legacy TV1 source unavailable');const source=sources[0];const text=source.textContent.replace(/\s/g,'');if(!text.includes('157.30.10.11,0001010')||!text.includes('Long'))throw Error('legacy parameter fingerprint mismatch');const buttons=Array.from(source.querySelectorAll('button[data-qa-id=legend-show-hide-action]'));if(buttons.length!==1)throw Error('unique legacy visibility button unavailable');const state=buttons[0].getAttribute('aria-label');if(state==='表示')return {hidden:true,changed:false};if(state!=='非表示'||buttons[0].getAttribute('title')!=='非表示')throw Error('legacy visibility state unknown');for(const type of ['mousedown','mouseup','click'])buttons[0].dispatchEvent(new MouseEvent(type,{bubbles:true}));return {hidden:true,changed:true};" }
        'test_legacy_source_inspect' { return "const sources=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent.trim()==='Loop IFD fixed grid (TV1)'&&!e.querySelector('[class*=activeStrategy]')&&!e.querySelector('[class*=openedInPineEditor]'));if(sources.length!==1)throw Error('unique legacy TV1 source unavailable');const source=sources[0];return {text:source.textContent.trim().slice(0,400),buttons:Array.from(source.querySelectorAll('button,[role=button],[data-qa-id]')).slice(0,30).map(e=>({tag:e.tagName,qa:e.getAttribute('data-qa-id'),title:e.getAttribute('title'),aria:e.getAttribute('aria-label'),classes:e.className,text:e.textContent.trim().slice(0,100)})),leafs:Array.from(source.querySelectorAll('span,div')).filter(e=>e.children.length===0).slice(0,25).map(e=>({qa:e.getAttribute('data-qa-id'),title:e.getAttribute('title'),classes:e.className,text:e.textContent.trim().slice(0,150)}))};" }
        'test_layout_metrics' { return "return {innerWidth,innerHeight,devicePixelRatio,scrollX,scrollY,visualViewport:window.visualViewport?{width:visualViewport.width,height:visualViewport.height,offsetLeft:visualViewport.offsetLeft,offsetTop:visualViewport.offsetTop,pageLeft:visualViewport.pageLeft,pageTop:visualViewport.pageTop,scale:visualViewport.scale}:null};" }
        'test_report_close' { return "const active=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent.trim()==='Loop IFD fixed grid (TV1)'&&e.querySelector('[class*=activeStrategy]'));if(active.length!==1)throw Error('unique active TV1 unavailable');const buttons=Array.from(document.querySelectorAll('[data-qa-id=backtesting]')).filter(e=>e.getClientRects().length&&e.getAttribute('aria-label')==='ストラテジーレポートを閉じる');if(buttons.length!==1)throw Error('unique Report close unavailable');buttons[0].click();return {closed:true,visibleChartRecalculation:'record new observed period'};" }
        'test_summary_capture' { return "const active=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent.trim()==='Loop IFD fixed grid (TV1)'&&e.querySelector('[class*=activeStrategy]'));if(active.length!==1)throw Error('unique active TV1 unavailable');const wrappers=Array.from(document.querySelectorAll('[data-qa-id=pane-widget-chart-gui-wrapper]')).filter(e=>e.getClientRects().length);if(wrappers.length!==1)throw Error('unique chart canvas wrapper unavailable');const r=wrappers[0].getBoundingClientRect();if(r.width<300||r.height<350||r.x<0||r.y<0||r.right>innerWidth||r.bottom>innerHeight)throw Error('summary crop unavailable; enlarge chart panel');const width=Math.min(550,r.width);const height=Math.min(450,r.height);const layers=Array.from(wrappers[0].querySelectorAll('canvas')).filter(e=>e.getClientRects().length);if(layers.length<1||layers.length>5)throw Error('chart canvas layer schema mismatch');const output=document.createElement('canvas');output.width=Math.ceil(width);output.height=Math.ceil(height);const ctx=output.getContext('2d');ctx.fillStyle='#ffffff';ctx.fillRect(0,0,width,height);for(const layer of layers){const box=layer.getBoundingClientRect();if(Math.abs(box.x-r.x)>1||Math.abs(box.y-r.y)>1||Math.abs(box.width-r.width)>1||Math.abs(box.height-r.height)>1||layer.width<box.width||layer.height<box.height)throw Error('chart canvas dimensions mismatch');const sx=(r.width-width)*layer.width/r.width;const sw=width*layer.width/r.width;const sh=height*layer.height/r.height;ctx.drawImage(layer,sx,0,sw,sh,0,0,width,height);}const data=output.toDataURL('image/png').split(',')[1];return {mime:'image/png',data,clip:{x:r.right-width,y:r.y,width,height},source:'verified chart canvas overlay composite'};" }
        'test_summary_bounds' { return "return {viewport:{width:innerWidth,height:innerHeight,dpr:devicePixelRatio},canvases:Array.from(document.querySelectorAll('canvas')).filter(e=>e.getClientRects().length).slice(0,25).map(e=>{const r=e.getBoundingClientRect();const ancestors=[];for(let p=e.parentElement,i=0;p&&i<4;p=p.parentElement,i++)ancestors.push({tag:p.tagName,name:p.getAttribute('data-name'),qa:p.getAttribute('data-qa-id'),className:p.className});return {rect:{x:r.x,y:r.y,width:r.width,height:r.height},ancestors}})};" }
        'test_trade_metadata' { return "const bars=Array.from(document.querySelectorAll('[data-qa-id=backtesting-report-toolbar]')).filter(e=>e.getClientRects().length);if(bars.length!==1)throw Error('unique Report toolbar unavailable');const panel=bars[0].closest('.layout__area--bottom');if(!panel||!panel.innerText.includes('Loop IFD fixed grid (TV1)'))throw Error('TV1 Report unavailable');return {rows:Array.from(panel.querySelectorAll('tr,[role=row]')).slice(0,30).map(r=>({text:r.textContent.trim().slice(0,1200),qa:r.getAttribute('data-qa-id'),cells:Array.from(r.querySelectorAll('td,th,[role=gridcell],[role=cell]')).slice(0,20).map(e=>({text:e.textContent.trim().slice(0,400),title:e.getAttribute('title'),aria:e.getAttribute('aria-label'),qa:e.getAttribute('data-qa-id')}))})),attributes:Array.from(panel.querySelectorAll('[data-qa-id],[data-name]')).filter(e=>/trade|entry|exit|signal|list|row|table/.test([e.getAttribute('data-qa-id'),e.getAttribute('data-name')].join(' '))).slice(0,60).map(e=>({tag:e.tagName,qa:e.getAttribute('data-qa-id'),name:e.getAttribute('data-name'),role:e.getAttribute('role'),title:e.getAttribute('title'),aria:e.getAttribute('aria-label'),text:e.textContent.trim().slice(0,300)}))};" }
        'settings_direction_short_select' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1||!Array.from(dialogs[0].querySelectorAll('[role=combobox]')).some(e=>['ロング','ショート'].includes(e.textContent.trim())))throw Error('TV1 direction dialog unavailable');const options=Array.from(document.querySelectorAll('[role=option]')).filter(e=>e.getClientRects().length&&e.textContent.trim()==='ショート');if(options.length!==1)throw Error('unique Short option unavailable');options[0].click();return {direction:'ショート'};" }
        'test_report_trades_tab' { return "const groups=Array.from(document.querySelectorAll('[data-qa-id=backtesting-report-toolbar-tabs]')).filter(e=>e.getClientRects().length);if(groups.length!==1)throw Error('unique Report tabs unavailable');const tabs=Array.from(groups[0].querySelectorAll('[role=tab]'));if(tabs.length!==2)throw Error('Report tab schema mismatch');tabs[1].click();return {selectedIndex:1,aria:tabs[1].getAttribute('aria-label'),title:tabs[1].getAttribute('title')};" }
        'settings_direction_short_open' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1)throw Error('unique TV1 dialog unavailable');const combos=Array.from(dialogs[0].querySelectorAll('[role=combobox]')).filter(e=>e.getClientRects().length&&['ロング','ショート'].includes(e.textContent.trim()));if(combos.length!==1)throw Error('unique direction combo unavailable');combos[0].click();return {opened:true};" }
        'settings_options_read' { return "return {listboxes:Array.from(document.querySelectorAll('[role=listbox]')).filter(e=>e.getClientRects().length).slice(0,5).map(e=>({text:e.innerText.slice(0,1000),options:Array.from(e.querySelectorAll('[role=option]')).map(o=>({text:o.textContent.trim(),qa:o.getAttribute('data-qa-id'),name:o.getAttribute('data-name'),selected:o.getAttribute('aria-selected')})).slice(0,20)})),options:Array.from(document.querySelectorAll('[role=option]')).filter(e=>e.getClientRects().length).slice(0,20).map(e=>({text:e.textContent.trim(),qa:e.getAttribute('data-qa-id'),name:e.getAttribute('data-name')}))};" }
        { @('case_long_max2','case_long_max1','case_long_ceiling','case_long_fifo','case_long_gap_dense','case_grid321','case_short_max1','case_short_max2','case_short_ceiling','case_margin_long_single','case_margin_long_multi','case_margin_short_single','case_margin_short_multi','case_margin_long_single_adjusted','case_margin_long_full_single','case_margin_long_full_multi','case_margin_short_full_single','case_margin_short_full_multi','case_margin_long_full_final','case_margin_short_partial_single_final','case_margin_short_partial_multi_final') -ccontains $_ } {
            $values = Get-CaseValues $Action | ConvertTo-Json -Compress
            $direction = if ($Action.Contains('_short_')) { 'ショート' } else { 'ロング' }
            return "const title='Loop IFD fixed grid (TV1)';const sources=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent.trim()===title&&e.querySelector('[class*=activeStrategy]')&&e.querySelector('[class*=openedInPineEditor]'));if(sources.length!==1)throw Error('owned active TV1 unavailable');const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes(title));if(dialogs.length!==1)throw Error('unique TV1 dialog unavailable');const d=dialogs[0];if(!Array.from(d.querySelectorAll('[role=combobox]')).some(e=>e.textContent.trim()==='$direction'))throw Error('case direction mismatch');for(const label of ['アンカー価格','グリッド間隔','利確幅','数量','グリッド数','同時稼働上限'])if(!d.textContent.includes(label))throw Error('parameter label schema mismatch');const inputs=Array.from(d.querySelectorAll('input')).filter(e=>e.getClientRects().length);if(inputs.length!==10||inputs.some(e=>e.type==='password'))throw Error('parameter field schema mismatch');const values=$values;for(let i=0;i<6;i++){Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(inputs[i+4],String(values[i]));inputs[i+4].dispatchEvent(new Event('input',{bubbles:true}));inputs[i+4].dispatchEvent(new Event('change',{bubbles:true}));}return {case:'$Action',values};"
        }
        'properties_capital_2m' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1)throw Error('unique TV1 dialog unavailable');const inputs=Array.from(dialogs[0].querySelectorAll('input[data-qa-id~=initial-capital-input]')).filter(e=>e.getClientRects().length);if(inputs.length!==1)throw Error('unique capital field unavailable');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(inputs[0],'2000000');inputs[0].dispatchEvent(new Event('input',{bubbles:true}));inputs[0].dispatchEvent(new Event('change',{bubbles:true}));return {capital:2000000};" }
        'settings_apply' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1)throw Error('unique TV1 dialog unavailable');const buttons=Array.from(dialogs[0].querySelectorAll('[data-qa-id=submit-button]')).filter(e=>e.getClientRects().length);if(buttons.length!==1)throw Error('unique apply button unavailable');buttons[0].click();return {applied:true};" }
        'test_report_read' { return "const toolbars=Array.from(document.querySelectorAll('[data-qa-id=backtesting-report-toolbar]')).filter(e=>e.getClientRects().length);if(toolbars.length!==1)throw Error('unique Report toolbar unavailable');const panel=toolbars[0].closest('.layout__area--bottom');if(!panel)throw Error('Report panel unavailable');const text=panel.innerText;if(!text.includes('Loop IFD fixed grid (TV1)'))throw Error('TV1 Report unavailable');return {text:text.slice(0,18000),tabs:Array.from(panel.querySelectorAll('[role=tab]')).map(e=>({text:e.textContent.trim(),selected:e.getAttribute('aria-selected')})),tables:Array.from(panel.querySelectorAll('table')).slice(0,3).map(e=>e.innerText.slice(0,12000))};" }
        'test_report_inventory' { return "const buttons=Array.from(document.querySelectorAll('[data-qa-id=backtesting]')).filter(e=>e.getClientRects().length);return {buttons:buttons.map(e=>({tag:e.tagName,text:e.textContent.trim().slice(0,100)})),ancestors:buttons.slice(0,3).map(e=>{const rows=[];for(let p=e.parentElement,i=0;p&&i<6;p=p.parentElement,i++)rows.push({tag:p.tagName,name:p.getAttribute('data-name'),qa:p.getAttribute('data-qa-id'),className:p.className});return rows}),panels:Array.from(document.querySelectorAll('[data-name*=backtesting],[data-qa-id*=backtesting],[data-name*=strategy-tester],[data-qa-id*=strategy-tester]')).slice(0,30).map(e=>({tag:e.tagName,name:e.getAttribute('data-name'),qa:e.getAttribute('data-qa-id'),className:e.className,visible:!!e.getClientRects().length}))};" }
        'test_inventory' { return "const controls=Array.from(document.querySelectorAll('button,[role=button],[role=tab]')).filter(e=>e.getClientRects().length).map(e=>({tag:e.tagName,role:e.getAttribute('role'),name:e.getAttribute('data-name'),qa:e.getAttribute('data-qa-id'),aria:e.getAttribute('aria-label'),title:e.getAttribute('title'),text:e.textContent.trim().slice(0,160)})).filter(e=>/strategy|report|backtest|レポート|ストラテジー|コンソール|console|error/i.test([e.name,e.qa,e.aria,e.title,e.text].join(' '))).slice(0,60);const tables=Array.from(document.querySelectorAll('table')).filter(e=>/Loop IFD TV1|TV-GRID/.test(e.textContent)).slice(0,5).map(e=>e.innerText.slice(0,12000));const errors=Array.from(document.querySelectorAll('[data-name=pine-console] [data-type=error],[data-qa-id=pine-console] [data-type=error],.pine-editor-error')).slice(0,10).map(e=>e.innerText.slice(0,3000));const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)')).map(e=>({tabs:Array.from(e.querySelectorAll('[role=tab],button')).map(t=>({text:t.textContent.trim().slice(0,80),role:t.getAttribute('role'),qa:t.getAttribute('data-qa-id'),name:t.getAttribute('data-name')})).slice(0,30),inputs:Array.from(e.querySelectorAll('input')).map(i=>({type:i.type,aria:i.getAttribute('aria-label'),qa:i.getAttribute('data-qa-id'),name:i.getAttribute('name'),id:i.id,value:i.type==='password'?null:i.value})).slice(0,40)}));return {controls,tables,errors,dialogs};" }
        'settings_parameters_tab' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1)throw Error('unique TV1 dialog unavailable');const tabs=Array.from(dialogs[0].querySelectorAll('[role=tab],button')).filter(e=>['パラメーター','パラメータ','Inputs','入力'].includes(e.textContent.trim()));if(tabs.length!==1)throw Error('unique parameter tab unavailable');tabs[0].click();return {selected:'parameters'};" }
        'settings_properties_tab' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1)throw Error('unique TV1 dialog unavailable');const tabs=Array.from(dialogs[0].querySelectorAll('[role=tab],button')).filter(e=>['プロパティ','Properties'].includes(e.textContent.trim()));if(tabs.length!==1)throw Error('unique properties tab unavailable');tabs[0].click();return {selected:'properties'};" }
        'settings_cancel' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.textContent.includes('Loop IFD fixed grid (TV1)'));if(dialogs.length!==1)throw Error('unique TV1 dialog unavailable');const buttons=Array.from(dialogs[0].querySelectorAll('button')).filter(e=>['キャンセル','Cancel'].includes(e.textContent.trim()));if(buttons.length!==1)throw Error('unique cancel button unavailable');buttons[0].click();return {cancelled:true};" }
        'bootstrap_add_tv1' { return Get-Action 'bootstrap_editor_select_all' }
        'bootstrap_repair_tv1_clipboard' { return Get-Action 'bootstrap_editor_select_all' }
        'bootstrap_editor_copy_hash' { return Get-Action 'bootstrap_editor_select_all' }
        'bootstrap_chart_identity' { return "const symbols=Array.from(document.querySelectorAll('button,[role=button]')).filter(e=>e.getAttribute('aria-label')==='シンボルの変更'&&e.getClientRects().length);const intervals=Array.from(document.querySelectorAll('button,[role=button]')).filter(e=>e.getAttribute('aria-label')==='時間足の変更'&&e.getClientRects().length);if(symbols.length!==1||intervals.length!==1)throw Error('unique chart identity controls unavailable');const headerAncestors=[];for(let p=symbols[0].parentElement,i=0;p&&i<4;p=p.parentElement,i++)headerAncestors.push({tag:p.tagName,name:p.getAttribute('data-name'),qa:p.getAttribute('data-qa-id'),providerFXCM:p.textContent.includes('FXCM')});const url=new URL(location.href);return {symbol:symbols[0].textContent.trim().slice(0,80),interval:intervals[0].textContent.trim().slice(0,40),requestedSymbol:url.searchParams.get('symbol'),requestedInterval:url.searchParams.get('interval'),headerAncestors,invalidSymbol:!!document.querySelector('[data-name=invalid-symbol]')};" }
        'bootstrap_legend_inspect' { return "return {sources:Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).slice(0,20).map(e=>({text:e.textContent.trim().slice(0,200),children:Array.from(e.querySelectorAll('span,div')).slice(0,40).map(t=>({tag:t.tagName,name:t.getAttribute('data-name'),qa:t.getAttribute('data-qa-id'),title:t.getAttribute('title'),className:t.className,leaf:t.children.length===0,text:t.children.length===0?t.textContent.trim().slice(0,160):null}))}))};" }
        'bootstrap_pine_open' { return "if(Array.from(document.querySelectorAll('[role=dialog]')).some(e=>e.getClientRects().length))throw Error('dialog open');const buttons=Array.from(document.querySelectorAll('button[data-name=pine-dialog-button]')).filter(e=>e.getClientRects().length);if(buttons.length!==1)throw Error('unique Pine opener unavailable');for(const type of ['mousedown','mouseup','click'])buttons[0].dispatchEvent(new MouseEvent(type,{bubbles:true}));return {opened:true};" }
        'bootstrap_chart_usdjpy5' { return Get-Action 'bootstrap_insert_tv1' }
        'bootstrap_insert_tv1' { return "return (async()=>{if(Array.from(document.querySelectorAll('[role=dialog]')).some(e=>e.getClientRects().length))throw Error('dialog open');if(document.querySelector('[data-qa-id=pine-script-title-button]')?.textContent?.trim()!=='名前なしのスクリプト')throw Error('unnamed editor required');const inputs=Array.from(document.querySelectorAll('.monaco-editor.pine-editor-monaco[role=code] textarea.inputarea')).filter(e=>e.getClientRects().length);if(inputs.length!==1||document.activeElement!==inputs[0])throw Error('unique focused Pine editor required');const e=inputs[0];if(e.value.length!==175||e.selectionStart!==0||e.selectionEnd!==175)throw Error('full default selection required');const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(e.value)))).map(x=>x.toString(16).padStart(2,'0')).join('');if(hash!=='e627e32206b21de8406371be3e54d70753f61baa57dc85db54de954467b259b3')throw Error('default source changed');return {ready:true}})();" }
        'bootstrap_symbol_providers_open' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.querySelector('[data-qa-id=symbol-search-input]'));if(dialogs.length!==1)throw Error('unique symbol dialog unavailable');const rows=Array.from(dialogs[0].querySelectorAll('[data-role=list-item][data-name=symbol-search-dialog-content-item]')).filter(e=>e.getClientRects().length);if(rows.length!==1||!rows[0].textContent.includes('USDJPY'))throw Error('unique USDJPY provider group unavailable');const expand=Array.from(rows[0].querySelectorAll('button,[role=button],div,span')).filter(e=>e.getClientRects().length&&e.children.length===0&&/^\+\d+$/.test(e.textContent.trim()));if(expand.length!==1)throw Error('unique provider expansion unavailable');for(const type of ['mousedown','mouseup','click'])expand[0].dispatchEvent(new MouseEvent(type,{bubbles:true}));return {expanded:true};" }
        'bootstrap_interval_open' { return "if(Array.from(document.querySelectorAll('[role=dialog]')).some(e=>e.getClientRects().length))throw Error('dialog open');const buttons=Array.from(document.querySelectorAll('button,[role=button]')).filter(e=>e.getAttribute('aria-label')==='時間足の変更'&&e.getClientRects().length);if(buttons.length!==1)throw Error('unique interval button unavailable');for(const type of ['mousedown','mouseup','click'])buttons[0].dispatchEvent(new MouseEvent(type,{bubbles:true}));return {opened:true};" }
        'bootstrap_symbol_result_inspect' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.querySelector('[data-qa-id=symbol-search-input]'));if(dialogs.length!==1)throw Error('unique symbol dialog unavailable');return {text:dialogs[0].innerText.slice(0,3000),rows:Array.from(dialogs[0].querySelectorAll('[data-symbol-full],[data-symbol],[data-role]')).slice(0,40).map(e=>({tag:e.tagName,role:e.getAttribute('data-role'),symbol:e.getAttribute('data-symbol'),symbolFull:e.getAttribute('data-symbol-full'),qa:e.getAttribute('data-qa-id'),name:e.getAttribute('data-name'),text:e.textContent.trim().slice(0,200)}))};" }
        'bootstrap_symbol_search' { return "const inputs=Array.from(document.querySelectorAll('[role=dialog] input[data-qa-id=symbol-search-input]')).filter(e=>e.getClientRects().length);if(inputs.length!==1)throw Error('unique symbol search unavailable');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(inputs[0],'USDJPY');inputs[0].dispatchEvent(new Event('input',{bubbles:true}));return {query:'USDJPY',requiredProvider:'FXCM'};" }
        'bootstrap_symbol_search_close' { return "const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length&&e.querySelector('[data-qa-id=symbol-search-input]'));if(dialogs.length!==1)throw Error('unique symbol dialog unavailable');const buttons=Array.from(dialogs[0].querySelectorAll('[data-qa-id=close]')).filter(e=>e.getClientRects().length);if(buttons.length!==1)throw Error('unique symbol close unavailable');for(const type of ['mousedown','mouseup','click'])buttons[0].dispatchEvent(new MouseEvent(type,{bubbles:true}));return {closed:true};" }
        'bootstrap_editor_select_all' { return "if(Array.from(document.querySelectorAll('[role=dialog]')).some(e=>e.getClientRects().length))throw Error('dialog open');const title=document.querySelector('[data-qa-id=pine-script-title-button]')?.textContent?.trim();if(!['名前なしのスクリプト','Loop IFD fixed grid (TV1)'].includes(title))throw Error('known Pine editor title required');const inputs=Array.from(document.querySelectorAll('.monaco-editor.pine-editor-monaco[role=code] textarea.inputarea')).filter(e=>e.getClientRects().length);if(inputs.length!==1)throw Error('unique Pine textarea unavailable');inputs[0].focus();return {focused:true};" }
        'bootstrap_editor_inspect' { return "const editors=Array.from(document.querySelectorAll('.monaco-editor.pine-editor-monaco[role=code]')).filter(e=>e.getClientRects().length);if(editors.length!==1)throw Error('unique Pine editor unavailable');return {title:document.querySelector('[data-qa-id=pine-script-title-button]')?.textContent?.trim()||null,visibleCode:Array.from(editors[0].querySelectorAll('.view-line')).map(e=>e.textContent).join('\n').slice(0,2000),renderedLineNumbers:editors[0].querySelectorAll('.line-numbers').length};" }
        'bootstrap_symbol_open' { return "const buttons=Array.from(document.querySelectorAll('button,[role=button]')).filter(e=>e.getAttribute('aria-label')==='シンボルの変更'&&e.getClientRects().length);if(buttons.length!==1)throw Error('unique symbol button unavailable');for(const type of ['mousedown','mouseup','click'])buttons[0].dispatchEvent(new MouseEvent(type,{bubbles:true}));return {opened:true};" }
        'bootstrap_inventory' { return @'
const attr=e=>({tag:e.tagName,name:e.getAttribute('data-name'),qa:e.getAttribute('data-qa-id'),aria:e.getAttribute('aria-label'),visible:!!e.getClientRects().length});
const controls=Array.from(document.querySelectorAll('button,[role=button]')).map(e=>({...attr(e),title:e.getAttribute('title'),text:(e.textContent||'').trim().slice(0,120)})).filter(e=>/symbol|interval|timeframe|pine|editor|chart|スクリプト|エディタ|チャート|シンボル|時間足/i.test([e.name,e.qa,e.aria,e.title,e.text].join(' '))).slice(0,80);
const editors=Array.from(document.querySelectorAll('textarea,[contenteditable=true],.monaco-editor')).slice(0,20).map(e=>({...attr(e),role:e.getAttribute('role'),classes:e.className}));
const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.getClientRects().length).slice(0,5).map(e=>({heading:(e.querySelector('h1,h2,[role=heading]')?.textContent||'').trim().slice(0,160),inputs:Array.from(e.querySelectorAll('input')).slice(0,15).map(b=>({...attr(b),type:b.type,placeholder:b.getAttribute('placeholder')})),buttons:Array.from(e.querySelectorAll('button')).slice(0,15).map(b=>({...attr(b),text:b.textContent.trim().slice(0,80)})),rows:e.querySelector('[data-qa-id=symbol-search-input]')?Array.from(e.querySelectorAll('[role=row],[data-role=search-result-item],[data-symbol-full],[data-symbol]')).slice(0,20).map(r=>({...attr(r),text:r.textContent.trim().slice(0,200),symbol:r.getAttribute('data-symbol'),symbolFull:r.getAttribute('data-symbol-full')})):[]}));
return {controls,editors,dialogs,monaco:{present:typeof window.monaco!=='undefined',getEditors:typeof window.monaco?.editor?.getEditors==='function',getModels:typeof window.monaco?.editor?.getModels==='function',require:typeof window.require==='function'}};
'@
        }
        'snapshot' { return "const prefix='Loop IFD fixed grid (TV1)';const legends=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).slice(0,20).map(e=>({title:e.textContent.trim().slice(0,200)}));const inventory=Array.from(document.querySelectorAll('[data-qa-id=legend-settings-action]')).slice(0,20).map(b=>{const a=[];for(let p=b.parentElement,i=0;p&&i<5;p=p.parentElement,i++)a.push({tag:p.tagName,name:p.getAttribute('data-name'),qa:p.getAttribute('data-qa-id'),titles:Array.from(p.querySelectorAll('[data-qa-id=legend-source-title]')).map(t=>t.textContent.trim().slice(0,200))});return a});const reports=Array.from(document.querySelectorAll('[data-name=strategy-tester]')).map(e=>e.innerText).join('\n').slice(0,12000);const dialogs=Array.from(document.querySelectorAll('[role=dialog]')).filter(e=>e.innerText.includes(prefix)).map(e=>e.innerText).join('\n').slice(0,12000);const diagnostics=Array.from(document.querySelectorAll('[data-name=chart-table]')).filter(e=>e.innerText.includes('TV1')||e.innerText.includes('TV-GRID')).map(e=>e.innerText).join('\n').slice(0,12000);return {legends,inventory,reports,dialogs,diagnostics};" }
        'settings' { return "const prefix='Loop IFD fixed grid (TV1)';let sources=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent?.trim()===prefix&&e.querySelector('[class*=activeStrategy]'));if(sources.length>1)sources=sources.filter(e=>e.querySelector('[class*=openedInPineEditor]'));if(sources.length!==1)throw Error('unique active TV1 strategy unavailable');const b=Array.from(sources[0].querySelectorAll('[data-qa-id=legend-settings-action]'));if(b.length!==1)throw Error('unique TV1 settings unavailable');for(const type of ['mousedown','mouseup','click'])b[0].dispatchEvent(new MouseEvent(type,{bubbles:true}));return {opened:true,strategy:prefix};" }
        'parameters' { return "return {dialogs:Array.from(document.querySelectorAll('[role=dialog]')).map(e=>e.innerText).join('\n').slice(0,12000)};" }
        'properties' { return "return {dialogs:Array.from(document.querySelectorAll('[role=dialog]')).map(e=>e.innerText).join('\n').slice(0,12000)};" }
        default { throw 'unsupported action' }
    }
}
function Get-CaseValues([string]$Case) {
    switch -CaseSensitive ($Case) {
        'case_long_max2' { return @(157.3,0.1,0.1,1000,2,2) }
        'case_long_fifo' { return @(157.2,0.1,0.1,1000,2,2) }
        'case_long_gap_dense' { return @(157.3,0.001,0.1,1,320,320) }
        'case_short_max2' { return @(157.3,0.1,0.1,1000,2,2) }
        'case_long_max1' { return @(157.3,0.1,0.1,1000,2,1) }
        'case_short_max1' { return @(157.3,0.1,0.1,1000,2,1) }
        'case_long_ceiling' { return @(157.3,0.1,0.1,1,320,320) }
        'case_short_ceiling' { return @(157.3,0.1,0.1,1,320,320) }
        'case_margin_long_single' { return @(157.3,0.1,1,1000,1,1) }
        'case_margin_long_multi' { return @(157.3,0.1,1,1000,2,2) }
        'case_margin_short_single' { return @(157.3,0.1,1,1000,1,1) }
        'case_margin_short_multi' { return @(157.3,0.1,1,1000,2,2) }
        'case_margin_long_single_adjusted' { return @(157.3,0.1,1,1000,1,1) }
        'case_margin_long_full_single' { return @(157.3,0.1,1,1000,1,1) }
        'case_margin_long_full_multi' { return @(157.3,0.1,1,1000,2,2) }
        'case_margin_short_full_single' { return @(157.3,0.1,1,1000,1,1) }
        'case_margin_short_full_multi' { return @(157.3,0.1,1,1000,2,2) }
        'case_margin_long_full_final' { return @(157.3,0.1,1,1000,1,1) }
        'case_margin_short_partial_single_final' { return @(157.3,0.1,1,1000,1,1) }
        'case_margin_short_partial_multi_final' { return @(157.3,0.01,1,1000,2,2) }
        'case_grid321' { return @(157.3,0.1,0.1,1,321,2) }
        default { throw 'unsupported case' }
    }
}
function Get-PeriodValues([string]$Case) {
    switch -CaseSensitive ($Case) {
        'period_aligned' { return @('2026-09-25','23:40','2026-09-26','06:00') }
        'period_bad_start' { return @('2026-09-25','23:41','2026-09-26','06:00') }
        'period_bad_end' { return @('2026-09-25','23:40','2026-09-26','05:59') }
        'period_pending_end' { return @('2026-09-25','23:40','2026-09-25','23:55') }
        'period_fifo_mid' { return @('2026-09-25','23:40','2026-09-26','01:35') }
        'period_reentry_end' { return @('2026-09-25','23:40','2026-09-26','00:20') }
        'period_margin_late' { return @('2026-09-26','00:30','2026-09-26','06:00') }
        'period_gap_week' { return @('2026-09-18','23:40','2026-09-26','06:00') }
        'period_weekend_end' { return @('2026-09-18','23:40','2026-09-20','12:00') }
        'period_closed_end' { return @('2026-09-18','23:40','2026-09-19','06:01') }
        'period_before_history' { return @('2020-01-01','09:00','2020-01-02','09:00') }
        'period_future' { return @('2027-01-01','09:00','2027-01-02','09:00') }
        default { throw 'unsupported period case' }
    }
}
function Get-RuntimeVariantHashes {
    return @{
        runtime_red01=@('01-status.mutation','fe4b9dd08f16393cb29fa8482172830d4d904ce496983c2ce67a969069fd8b71')
        runtime_red02=@('02-state.mutation','00398a2ae344da28c4e9a245c364f646989d98fb78f229650edb3b7ead899942')
        runtime_red03=@('03-error.mutation','8855db6f0765e1a58564847f570e750c3b1cc3e63d8e4f6ffedd3fa42ec2e056')
        runtime_red04=@('04-level-ticks.mutation','83dbfa4591e30c2e123194dca78409319f591e1bbc649a301fc6310d418a95d9')
        runtime_red05=@('05-gross-ticks.mutation','bed8177590f627833455c26a4191f18bf9ee516b679e096800274bef2c44d63e')
        runtime_red06=@('06-hard-max-319.mutation','3f914b5105ca3c9f0275267bd19664199b11f49f64ed265910988fca0d95ef5f')
        runtime_observer=@('observer-append.md','df8ccb868be44b72180786e84085e94b6d29b9ef9f234b47427a80f73a933148')
        runtime_margin_observer=@('observer-margin-append.md','0b83fa8cda3867292f108c9c89561c5921230af174507097fd5e95d53e7cc6f1')
        runtime_gap_observer=@('observer-gap-append.md','d38a6b30acca1b3311c1c7714d921bdf1580d9378d0c58a6ac24d457979b2f91')
        runtime_gap_proof_observer=@('observer-gap-proof-append.md','557261ccf46239888c0244a60f569f76580da9b6d75f733c4b8e8287ae03e3b4')
        runtime_gap_search_observer=@('observer-gap-search-append.md','e11c0095659aff458ce2093077cd7638902f9e9b297b4f1e1458cd8c1039b2cc')
    }
}
function Get-TextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false,$true).GetBytes($Text)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Get-RuntimeSource([string]$Action) {
    $canonical = 'bd2a67d702dfcf248876e9acf52d19761e29ee4ac419604e00b5ece80ce0492f'
    $sourcePath = '\\wsl.localhost\Ubuntu-24.04\home\issei\loopifd-backtest-worktrees\issue-43-tv2-manual-progress\integrations\tradingview\loop-grid-strategy.pine'
    $text = [Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($sourcePath))
    if ((Get-TextHash $text) -cne $canonical) { throw 'canonical source digest changed' }
    if ($Action -ceq 'runtime_canonical_restore') { return @{Text=$text;Hash=$canonical} }
    $variants = Get-RuntimeVariantHashes
    if (-not $variants.ContainsKey($Action)) { throw 'unsupported runtime variant' }
    $entry = $variants[$Action]
    $recipePath = Join-Path '\\wsl.localhost\Ubuntu-24.04\home\issei\loopifd-backtest\.git\codex-handoffs\issue43-runtime-mutations' $entry[0]
    if ($Action -ceq 'runtime_observer' -or $Action -ceq 'runtime_margin_observer' -or $Action -ceq 'runtime_gap_observer' -or $Action -ceq 'runtime_gap_proof_observer' -or $Action -ceq 'runtime_gap_search_observer') {
        $recipeText = [IO.File]::ReadAllText($recipePath).Replace("`r`n","`n")
        $blocks = [Regex]::Matches($recipeText,'(?s)```pine\n(.*?)\n```')
        $expectedBlocks=if ($Action -ceq 'runtime_margin_observer') { 14 } else { 6 }
        if ($blocks.Count -ne $expectedBlocks) { throw 'observer recipe block schema mismatch' }
        for ($index=0; $index -lt $expectedBlocks; $index+=2) {
            $find=$blocks[$index].Groups[1].Value
            $replace=$blocks[$index+1].Groups[1].Value
            if ($find.Length -eq 0 -or $text.IndexOf($find) -lt 0 -or $text.IndexOf($find) -ne $text.LastIndexOf($find)) { throw 'observer anchor is not unique' }
            $text=$text.Replace($find,$replace)
        }
        if ((Get-TextHash $text) -cne $entry[1]) { throw 'observer full source digest mismatch' }
        return @{Text=$text;Hash=$entry[1]}
    }
    $recipe = @{}
    foreach ($line in [IO.File]::ReadAllLines($recipePath)) {
        $pair=$line.Split([char[]]@('='),2,[StringSplitOptions]::None)
        if ($pair.Length -eq 2) { if ($recipe.ContainsKey($pair[0])) { throw 'duplicate recipe key' }; $recipe[$pair[0]]=$pair[1] }
    }
    $lines = $text.Split([string[]]@("`n"),[StringSplitOptions]::None)
    $index = [int]$recipe.canonical_line - 1
    $find = [string]$recipe.replace_exactly_once
    if ($index -lt 0 -or $index -ge $lines.Length -or $find.Length -eq 0 -or $lines[$index].IndexOf($find) -lt 0 -or $lines[$index].IndexOf($find) -ne $lines[$index].LastIndexOf($find)) { throw 'runtime recipe replacement is not unique' }
    $lines[$index] = $lines[$index].Replace($find,[string]$recipe.with)
    $text = $lines -join "`n"
    if ((Get-TextHash $text) -cne $entry[1]) { throw 'runtime variant digest does not match pinned recipe' }
    return @{Text=$text;Hash=$entry[1]}
}
function Write-Audit([string]$Action, [string]$Outcome, [string]$Target) {
    # 監査ログに DOM や入力値や口座情報を残さない。
    $row = @{time=[DateTime]::UtcNow.ToString('o'); action=$Action; outcome=$Outcome; target=$Target}
    [IO.File]::AppendAllText($script:Audit, (($row | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}
function Get-Request([string]$Line) {
    if ($Line.Length -gt 1024) { throw 'request too large' }
    $request = $Line | ConvertFrom-Json
    if (@($request.PSObject.Properties.Name).Count -ne 1 -or @($request.PSObject.Properties.Name)[0] -cne 'action' -or $request.action -isnot [string]) { throw 'only action field allowed' }
    $null = Get-Action $request.action
    return $request.action
}
function Get-Targets {
    $listeners = @(Get-NetTCPConnection -LocalPort 9333 -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -ne 1 -or $listeners[0].LocalAddress -cne '127.0.0.1') { throw 'dedicated loopback listener unavailable' }
    $process = Get-CimInstance Win32_Process -Filter ('ProcessId='+$listeners[0].OwningProcess)
    $profile = Join-Path $script:Root 'Profile'
    if ($process.Name -ine 'chrome.exe' -or $process.CommandLine -notlike ('*--user-data-dir="'+$profile+'"*') -or $process.CommandLine -notlike '*--remote-debugging-port=9333*') { throw 'listener does not own dedicated Chrome profile' }
    $targets = Invoke-RestMethod -Uri 'http://127.0.0.1:9333/json/list' -TimeoutSec 3 -UseBasicParsing
    foreach ($target in $targets) { Write-Output $target }
}
function Invoke-Cdp([string]$Method, $Params) {
    $script:Sequence++
    $id = $script:Sequence
    $bytes = [Text.Encoding]::UTF8.GetBytes((@{id=$id;method=$Method;params=$Params} | ConvertTo-Json -Depth 12 -Compress))
    $cts = [Threading.CancellationTokenSource]::new(30000)
    try {
        $script:Socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult() | Out-Null
        do {
            $stream = [IO.MemoryStream]::new()
            try {
                do {
                    $buffer = [byte[]]::new(8192)
                    $r = $script:Socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $cts.Token).GetAwaiter().GetResult()
                    if ($r.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'connection closed' }
                    $stream.Write($buffer,0,$r.Count)
                    if ($stream.Length -gt 1048576) { throw 'response too large' }
                } until ($r.EndOfMessage)
                $message = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
            } finally { $stream.Dispose() }
        } until ($message.id -eq $id)
        if ($message.error) { throw 'CDP command failed' }
        return $message.result
    } finally { $cts.Dispose() }
}
function Invoke-OwnedEditorKey([ValidateSet('a','c','v')][string]$Letter) {
    $code = @{a=65;c=67;v=86}[$Letter]
    foreach ($keyType in @('keyDown','keyUp')) {
        if (Test-Path $script:Revoked) { throw 'revoked' }
        $current = @(Get-Targets | Where-Object { $_.id -ceq $targetId })
        if ($current.Count -ne 1 -or -not (Test-ChartUrl $current[0].url)) { throw 'target unavailable or not allowed' }
        $check = Invoke-Cdp 'Runtime.evaluate' @{expression="(()=>{if(location.protocol!=='https:'||!['jp.tradingview.com','www.tradingview.com'].includes(location.hostname)||(location.port!==''&&location.port!=='443')||!location.pathname.startsWith('/chart/'))throw Error('origin denied');const e=document.activeElement;if(!e?.matches('textarea.inputarea')||!e.closest('.monaco-editor.pine-editor-monaco[role=code]')||!['名前なしのスクリプト','Loop IFD fixed grid (TV1)'].includes(document.querySelector('[data-qa-id=pine-script-title-button]')?.textContent?.trim())||Array.from(document.querySelectorAll('[role=dialog]')).some(d=>d.getClientRects().length))throw Error('editor focus lost');return true})()";returnByValue=$true}
        if ($check.exceptionDetails) { throw 'editor key focus check failed' }
        Write-Audit $action 'before-owned-key' $targetId
        $null = Invoke-Cdp 'Input.dispatchKeyEvent' @{type=$keyType;key=$Letter;code=('Key'+$Letter.ToUpperInvariant());windowsVirtualKeyCode=$code;nativeVirtualKeyCode=$code;modifiers=2}
    }
}
if ($Command -eq 'library') { return }
[IO.Directory]::CreateDirectory($script:Root) | Out-Null
switch ($Command) {
    'revoke' { [IO.File]::WriteAllText($script:Revoked,'revoked'); @{revoked=$true} | ConvertTo-Json -Compress; return }
    'resume' { if (Test-Path $script:Revoked) { Remove-Item -LiteralPath $script:Revoked }; @{revoked=$false} | ConvertTo-Json -Compress; return }
    'start' {
        if (Test-Path $script:Revoked) { throw 'revoked; resume required' }
        if (@(Get-NetTCPConnection -LocalPort 9333 -State Listen -ErrorAction SilentlyContinue).Count -gt 0) { throw 'port 9333 already in use; refusing another browser' }
        $chrome = @((Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),(Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),(Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $chrome) { throw 'Windows Chrome unavailable' }
        $profile = Join-Path $script:Root 'Profile'
        Start-Process -FilePath $chrome -ArgumentList @('--remote-debugging-address=127.0.0.1','--remote-debugging-port=9333', ('--user-data-dir="'+$profile+'"'),'--no-first-run','--no-default-browser-check','https://jp.tradingview.com/chart/') | Out-Null
        @{started=$true;login='manual login in dedicated profile required'} | ConvertTo-Json -Compress
        return
    }
    'status' {
        $targets = Get-Targets
        @{revoked=(Test-Path $script:Revoked);allowedChartCount=@($targets | Where-Object { $_.type -eq 'page' -and (Test-ChartUrl $_.url) }).Count;login='not inspected; login manually in dedicated profile'} | ConvertTo-Json -Compress
        return
    }
}
$script:Socket = [Net.WebSockets.ClientWebSocket]::new()
$script:Sequence = 0
try {
    if (Test-Path $script:Revoked) { throw 'revoked' }
    $targets = @(Get-Targets | Where-Object { $_.type -eq 'page' -and (Test-ChartUrl $_.url) })
    if ($targets.Count -ne 1) { throw 'exactly one allowed chart required' }
    $targetId = [string]$targets[0].id
    $socketUri = [Uri]$targets[0].webSocketDebuggerUrl
    if ($socketUri.Scheme -ne 'ws' -or $socketUri.Host -ne '127.0.0.1' -or $socketUri.Port -ne 9333 -or $socketUri.AbsolutePath -cne ('/devtools/page/'+$targetId)) { throw 'invalid debugger endpoint' }
    $cts = [Threading.CancellationTokenSource]::new(10000)
    try { $script:Socket.ConnectAsync($socketUri,$cts.Token).GetAwaiter().GetResult() | Out-Null } finally { $cts.Dispose() }
    @{ready=$true;target=$targetId;actions=@('snapshot','settings','parameters','properties','bootstrap_inventory','bootstrap_editor_inspect','bootstrap_symbol_open','bootstrap_symbol_search','bootstrap_symbol_search_close','bootstrap_symbol_result_inspect','bootstrap_symbol_providers_open','bootstrap_interval_open','bootstrap_editor_select_all','bootstrap_insert_tv1','bootstrap_chart_usdjpy5','bootstrap_pine_open','bootstrap_legend_inspect','bootstrap_chart_identity','bootstrap_editor_copy_hash','bootstrap_repair_tv1_clipboard')} | ConvertTo-Json -Compress
    while ($null -ne ($line = [Console]::ReadLine())) {
        $action = 'denied'
        try {
            if (Test-Path $script:Revoked) { throw 'revoked' }
            $action = Get-Request $line
            $runtimeVariant = @('runtime_red01','runtime_red02','runtime_red03','runtime_red04','runtime_red05','runtime_red06','runtime_observer','runtime_margin_observer','runtime_gap_observer','runtime_gap_proof_observer','runtime_gap_search_observer','runtime_canonical_restore') -ccontains $action
            $body = Get-Action $action
            $current = @(Get-Targets | Where-Object { $_.id -ceq $targetId })
            if ($current.Count -ne 1 -or -not (Test-ChartUrl $current[0].url)) { throw 'target unavailable or not allowed' }
            Write-Audit $action 'before' $targetId
            $expression = "(()=>{if(location.protocol!=='https:'||!['jp.tradingview.com','www.tradingview.com'].includes(location.hostname)||(location.port!==''&&location.port!=='443')||!location.pathname.startsWith('/chart/'))throw Error('origin denied');" + $body + '})()'
            $result = Invoke-Cdp 'Runtime.evaluate' @{expression=$expression;returnByValue=$true;awaitPromise=$true}
            if ($result.exceptionDetails) { throw 'guarded operation failed' }
            if ($action -ceq 'test_viewport_wide') {
                if (Test-Path $script:Revoked) { throw 'revoked' }
                $current = @(Get-Targets | Where-Object { $_.id -ceq $targetId })
                if ($current.Count -ne 1 -or -not (Test-ChartUrl $current[0].url)) { throw 'target unavailable or not allowed' }
                $check=Invoke-Cdp 'Runtime.evaluate' @{expression=$expression;returnByValue=$true;awaitPromise=$true}
                if ($check.exceptionDetails) { throw 'viewport origin check failed' }
                Write-Audit $action 'before-fixed-viewport' $targetId
                $null=Invoke-Cdp 'Emulation.setDeviceMetricsOverride' @{width=1440;height=1000;deviceScaleFactor=1;mobile=$false}
                $result=[pscustomobject]@{result=[pscustomobject]@{value=@{requestedWidth=1440;requestedHeight=1000;actualVerification='read layout metrics'}}}
            }
            if ($action -ceq 'test_source_more_native' -or $action -ceq 'test_editor_more_native') {
                Write-Audit $action 'before-native-hover' $targetId
                $null=Invoke-Cdp 'Input.dispatchMouseEvent' @{type='mouseMoved';x=$result.result.value.x;y=$result.result.value.y;buttons=0}
                [Threading.Thread]::Sleep(100)
                foreach ($mouseType in @('mousePressed','mouseReleased')) {
                    if (Test-Path $script:Revoked) { throw 'revoked' }
                    $current = @(Get-Targets | Where-Object { $_.id -ceq $targetId })
                    if ($current.Count -ne 1 -or -not (Test-ChartUrl $current[0].url)) { throw 'target unavailable or not allowed' }
                    $check=Invoke-Cdp 'Runtime.evaluate' @{expression=$expression;returnByValue=$true;awaitPromise=$true}
                    if ($check.exceptionDetails) { throw 'source More native bounds check failed' }
                    if ($mouseType -ceq 'mousePressed' -and $action -ceq 'test_editor_more_native' -and -not $check.result.value.ownedHit) { throw ('Pine More center hit mismatch: '+($check.result.value | ConvertTo-Json -Compress)) }
                    if ($mouseType -ceq 'mousePressed' -and $action -ceq 'test_source_more_native') {
                        $hit=Invoke-Cdp 'Runtime.evaluate' @{expression="(()=>{if(location.protocol!=='https:'||!['jp.tradingview.com','www.tradingview.com'].includes(location.hostname)||(location.port!==''&&location.port!=='443')||!location.pathname.startsWith('/chart/'))throw Error('origin denied');const sources=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent.trim()==='Loop IFD fixed grid (TV1)'&&e.querySelector('[class*=activeStrategy]')&&e.querySelector('[class*=openedInPineEditor]'));if(sources.length!==1)throw Error('owned source unavailable');const b=sources[0].querySelector('button[data-qa-id=legend-more-action]');if(!b)throw Error('More unavailable');const r=b.getBoundingClientRect();const hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);const ancestors=[];for(let p=hit?.parentElement,i=0;p&&i<2;p=p.parentElement,i++)ancestors.push({tag:p.tagName,qa:p.getAttribute('data-qa-id'),name:p.getAttribute('data-name'),classes:p.className});return {ownedHit:hit===b||b.contains(hit),buttonRect:{x:r.x,y:r.y,width:r.width,height:r.height},tag:hit?.tagName,qa:hit?.getAttribute('data-qa-id'),title:hit?.getAttribute('title'),hitClasses:hit?.className,ancestors}})()";returnByValue=$true}
                        if ($hit.exceptionDetails -or -not $hit.result.value.ownedHit) { throw ('More center hit mismatch: '+($hit.result.value | ConvertTo-Json -Compress)) }
                    }
                    Write-Audit $action 'before-native-more' $targetId
                    $buttons = if ($mouseType -ceq 'mousePressed') { 1 } else { 0 }
                    $null=Invoke-Cdp 'Input.dispatchMouseEvent' @{type=$mouseType;x=$check.result.value.x;y=$check.result.value.y;button='left';buttons=$buttons;clickCount=1}
                }
                $result=[pscustomobject]@{result=[pscustomobject]@{value=@{clicked=$true;popupVerification='read popup inventory; click alone does not prove menu opened'}}}
            }
            if ($action -ceq 'test_layout_metrics') {
                $dom = $result.result.value
                $metrics = Invoke-Cdp 'Page.getLayoutMetrics' @{}
                $result = [pscustomobject]@{result=[pscustomobject]@{value=@{dom=$dom;layoutViewport=$metrics.layoutViewport;visualViewport=$metrics.visualViewport;cssLayoutViewport=$metrics.cssLayoutViewport;cssVisualViewport=$metrics.cssVisualViewport}}}
            }
            if ($action -ceq 'bootstrap_chart_usdjpy5') {
                if (Test-Path $script:Revoked) { throw 'revoked' }
                $current = @(Get-Targets | Where-Object { $_.id -ceq $targetId })
                if ($current.Count -ne 1 -or -not (Test-ChartUrl $current[0].url)) { throw 'target unavailable or not allowed' }
                Write-Audit $action 'before-navigation' $targetId
                $navigation = Invoke-Cdp 'Page.navigate' @{url='https://jp.tradingview.com/chart/?symbol=FX%3AUSDJPY&interval=5'}
                if ($navigation.errorText) { throw 'fixed chart navigation failed' }
                $result = [pscustomobject]@{result=[pscustomobject]@{value=@{navigated=$true;requestedSymbol='FX:USDJPY';requestedProvider='FXCM';requestedInterval='5';actualVerification='required'}}}
            }
            if ($action -ceq 'bootstrap_insert_tv1') {
                $sourcePath = '\\wsl.localhost\Ubuntu-24.04\home\issei\loopifd-backtest-worktrees\issue-43-tv2-manual-progress\integrations\tradingview\loop-grid-strategy.pine'
                $sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $sourceHash = ([BitConverter]::ToString($sha.ComputeHash($sourceBytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
                if ($sourceHash -cne 'bd2a67d702dfcf248876e9acf52d19761e29ee4ac419604e00b5ece80ce0492f') { throw 'pinned source digest changed' }
                $sourceText = [Text.UTF8Encoding]::new($false,$true).GetString($sourceBytes)
                if (Test-Path $script:Revoked) { throw 'revoked' }
                $current = @(Get-Targets | Where-Object { $_.id -ceq $targetId })
                if ($current.Count -ne 1 -or -not (Test-ChartUrl $current[0].url)) { throw 'target unavailable or not allowed' }
                $check = Invoke-Cdp 'Runtime.evaluate' @{expression=$expression;returnByValue=$true;awaitPromise=$true}
                if ($check.exceptionDetails) { throw 'editor pre-insert verification failed' }
                Write-Audit $action 'before-insert' $targetId
                $null = Invoke-Cdp 'Input.insertText' @{text=$sourceText}
            }
            if ($action -ceq 'bootstrap_editor_select_all' -or $action -ceq 'bootstrap_insert_tv1' -or $action -ceq 'bootstrap_editor_copy_hash' -or $action -ceq 'bootstrap_repair_tv1_clipboard' -or $action -ceq 'bootstrap_add_tv1' -or $action -ceq 'runtime_chart_update' -or $runtimeVariant) {
                foreach ($keyType in @('keyDown','keyUp')) {
                    if (Test-Path $script:Revoked) { throw 'revoked' }
                    $current = @(Get-Targets | Where-Object { $_.id -ceq $targetId })
                    if ($current.Count -ne 1 -or -not (Test-ChartUrl $current[0].url)) { throw 'target unavailable or not allowed' }
                    $check = Invoke-Cdp 'Runtime.evaluate' @{expression="(()=>{if(location.protocol!=='https:'||!['jp.tradingview.com','www.tradingview.com'].includes(location.hostname)||(location.port!==''&&location.port!=='443')||!location.pathname.startsWith('/chart/'))throw Error('origin denied');const e=document.activeElement;if(!e?.matches('textarea.inputarea')||!e.closest('.monaco-editor.pine-editor-monaco[role=code]')||Array.from(document.querySelectorAll('[role=dialog]')).some(d=>d.getClientRects().length))throw Error('editor focus lost');return true})()";returnByValue=$true}
                    if ($check.exceptionDetails) { throw 'editor focus check failed' }
                    Write-Audit $action 'before-key' $targetId
                    $null = Invoke-Cdp 'Input.dispatchKeyEvent' @{type=$keyType;key='a';code='KeyA';windowsVirtualKeyCode=65;nativeVirtualKeyCode=65;modifiers=2}
                }
                $result = Invoke-Cdp 'Runtime.evaluate' @{expression="(async()=>{if(location.protocol!=='https:'||!['jp.tradingview.com','www.tradingview.com'].includes(location.hostname)||(location.port!==''&&location.port!=='443')||!location.pathname.startsWith('/chart/'))throw Error('origin denied');const e=document.activeElement;if(!e?.matches('textarea.inputarea')||!e.closest('.monaco-editor.pine-editor-monaco[role=code]'))throw Error('editor focus lost');const value=e.value;const bytes=new TextEncoder().encode(value);const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))).map(x=>x.toString(16).padStart(2,'0')).join('');const lines=value.replace(/\r\n/g,'\n').split('\n');const meaningful=lines.filter(x=>x.trim()&&!x.trim().startsWith('//'));const defaultTemplate=lines.some(x=>x.trim()==='//@version=6')&&meaningful.length===2&&meaningful[0].trim()==='indicator(\u0022マイスクリプト\u0022)'&&meaningful[1].trim()==='plot(close)';return {length:value.length,selectionStart:e.selectionStart,selectionEnd:e.selectionEnd,lineCount:lines.length,sha256:hash,defaultTemplate,title:document.querySelector('[data-qa-id=pine-script-title-button]')?.textContent?.trim()||null}})()";returnByValue=$true;awaitPromise=$true}
                if ($result.exceptionDetails) { throw 'editor selection inspect failed' }
                if ($action -ceq 'bootstrap_insert_tv1' -and ($result.result.value.sha256 -cne $sourceHash -or $result.result.value.selectionStart -ne 0 -or $result.result.value.selectionEnd -ne $sourceText.Length -or $result.result.value.length -ne $sourceText.Length)) { throw 'inserted source read-back mismatch; stop and inspect existing editor' }
            }
            if ($action -ceq 'bootstrap_editor_copy_hash' -or $action -ceq 'bootstrap_repair_tv1_clipboard' -or $action -ceq 'bootstrap_add_tv1' -or $action -ceq 'runtime_chart_update' -or $runtimeVariant) {
                Add-Type -AssemblyName System.Windows.Forms
                if (-not ('AgentBrowserClipboardSequence' -as [type])) { Add-Type 'using System.Runtime.InteropServices; public static class AgentBrowserClipboardSequence { [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber(); }' }
                $savedClipboard = [Windows.Forms.DataObject]::new()
                $clipboard = [Windows.Forms.Clipboard]::GetDataObject()
                if ($null -ne $clipboard) {
                    foreach ($format in $clipboard.GetFormats($false)) {
                        $data = $clipboard.GetData($format,$false)
                        if ($data -is [ICloneable]) { $data = $data.Clone() }
                        $savedClipboard.SetData($format,$false,$data)
                    }
                }
                $lastOwnedSequence = $null
                try {
                    $previousSequence = [AgentBrowserClipboardSequence]::GetClipboardSequenceNumber()
                    foreach ($keyType in @('keyDown','keyUp')) {
                        if (Test-Path $script:Revoked) { throw 'revoked' }
                        $current = @(Get-Targets | Where-Object { $_.id -ceq $targetId })
                        if ($current.Count -ne 1 -or -not (Test-ChartUrl $current[0].url)) { throw 'target unavailable or not allowed' }
                        $check = Invoke-Cdp 'Runtime.evaluate' @{expression="(()=>{if(location.protocol!=='https:'||!['jp.tradingview.com','www.tradingview.com'].includes(location.hostname)||(location.port!==''&&location.port!=='443')||!location.pathname.startsWith('/chart/'))throw Error('origin denied');const e=document.activeElement;if(!e?.matches('textarea.inputarea')||!e.closest('.monaco-editor.pine-editor-monaco[role=code]')||!['名前なしのスクリプト','Loop IFD fixed grid (TV1)'].includes(document.querySelector('[data-qa-id=pine-script-title-button]')?.textContent?.trim())||Array.from(document.querySelectorAll('[role=dialog]')).some(d=>d.getClientRects().length))throw Error('editor focus lost');return true})()";returnByValue=$true}
                        if ($check.exceptionDetails) { throw 'editor copy focus check failed' }
                        Write-Audit $action 'before-copy-key' $targetId
                        $null = Invoke-Cdp 'Input.dispatchKeyEvent' @{type=$keyType;key='c';code='KeyC';windowsVirtualKeyCode=67;nativeVirtualKeyCode=67;modifiers=2}
                    }
                    for ($attempt = 0; $attempt -lt 20 -and [AgentBrowserClipboardSequence]::GetClipboardSequenceNumber() -eq $previousSequence; $attempt++) { [Threading.Thread]::Sleep(50) }
                    if ([AgentBrowserClipboardSequence]::GetClipboardSequenceNumber() -eq $previousSequence) { throw 'editor copy did not update clipboard' }
                    $lastOwnedSequence = [AgentBrowserClipboardSequence]::GetClipboardSequenceNumber()
                    $copied = [Windows.Forms.Clipboard]::GetText([Windows.Forms.TextDataFormat]::UnicodeText)
                    if ($copied -cnotmatch '^//@version=6\r?\n' -or $copied -cnotmatch 'strategy\("Loop IFD fixed grid \(TV1\)"') { throw 'copied content is not owned TV1 Pine; no content returned' }
                    $normalized = $copied.Replace("`r`n","`n")
                    $copiedBytes = [Text.UTF8Encoding]::new($false,$true).GetBytes($normalized)
                    $sha = [Security.Cryptography.SHA256]::Create()
                    try { $copiedHash = ([BitConverter]::ToString($sha.ComputeHash($copiedBytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
                    if ($action -ceq 'bootstrap_repair_tv1_clipboard' -or $runtimeVariant) {
                        if ($runtimeVariant) {
                            $canonicalHash='bd2a67d702dfcf248876e9acf52d19761e29ee4ac419604e00b5ece80ce0492f'
                            $variants=Get-RuntimeVariantHashes
                            $knownHashes=@($canonicalHash,'543ca18dc190ddc5e12e96b874cb309b029b78f84de544938cde077e93ad2710','617b3f38752297f003f36ef5871aafd7c9193b757898ee8a56a1ea5dab589583','edae709d2486d06cdeba198f962a61500e2043c629646cf6104fff344a75edc5')+@($variants.Values | ForEach-Object { $_[1] })
                            if ($knownHashes -cnotcontains $copiedHash) { throw 'runtime source overwrite denied: unknown existing source' }
                            if ($action -cne 'runtime_canonical_restore' -and $copiedHash -cne $canonicalHash) { throw 'runtime Red requires canonical source first' }
                            $source=Get-RuntimeSource $action
                        } else {
                            if ($copiedHash -cne '46504a3f6eae3e698c299eb6a1c8ff3bc2472731cebaf01b1812fece6c3d2fb4' -or $normalized.Length -ne 686200) { throw 'repair denied: source is not exact agent-created corrupted draft' }
                            $source=Get-RuntimeSource 'runtime_canonical_restore'
                        }
                        $sourceText=$source.Text
                        $sourceHash=$source.Hash
                        if ([AgentBrowserClipboardSequence]::GetClipboardSequenceNumber() -ne $lastOwnedSequence) { throw 'clipboard changed concurrently; repair denied' }
                        Write-Audit $action 'before-pinned-clipboard' $targetId
                        [Windows.Forms.Clipboard]::SetText($sourceText,[Windows.Forms.TextDataFormat]::UnicodeText)
                        $lastOwnedSequence = [AgentBrowserClipboardSequence]::GetClipboardSequenceNumber()
                        Invoke-OwnedEditorKey 'v'
                        Invoke-OwnedEditorKey 'a'
                        $previousSequence = [AgentBrowserClipboardSequence]::GetClipboardSequenceNumber()
                        Invoke-OwnedEditorKey 'c'
                        for ($attempt = 0; $attempt -lt 20 -and [AgentBrowserClipboardSequence]::GetClipboardSequenceNumber() -eq $previousSequence; $attempt++) { [Threading.Thread]::Sleep(50) }
                        if ([AgentBrowserClipboardSequence]::GetClipboardSequenceNumber() -eq $previousSequence) { throw 'post-repair copy did not update clipboard' }
                        $lastOwnedSequence = [AgentBrowserClipboardSequence]::GetClipboardSequenceNumber()
                        $copied = [Windows.Forms.Clipboard]::GetText([Windows.Forms.TextDataFormat]::UnicodeText)
                        $normalized = $copied.Replace("`r`n","`n")
                        $sha = [Security.Cryptography.SHA256]::Create()
                        try { $copiedHash = ([BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false,$true).GetBytes($normalized)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
                        if ($copiedHash -cne $sourceHash) { throw 'repair full source digest mismatch; preserve draft and inspect' }
                    }
                    $result = [pscustomobject]@{result=[pscustomobject]@{value=@{length=$copied.Length;normalizedLFLength=$normalized.Length;normalizedLFSha256=$copiedHash;pinnedMatch=($copiedHash -ceq 'bd2a67d702dfcf248876e9acf52d19761e29ee4ac419604e00b5ece80ce0492f')}}}
                    if ($action -ceq 'runtime_chart_update') {
                        $variants=Get-RuntimeVariantHashes
                        $knownHashes=@('bd2a67d702dfcf248876e9acf52d19761e29ee4ac419604e00b5ece80ce0492f')+@($variants.Values | ForEach-Object { $_[1] })
                        if ($knownHashes -cnotcontains $copiedHash) { throw 'update denied: unknown full source digest' }
                        if (Test-Path $script:Revoked) { throw 'revoked' }
                        $current = @(Get-Targets | Where-Object { $_.id -ceq $targetId })
                        if ($current.Count -ne 1 -or -not (Test-ChartUrl $current[0].url)) { throw 'target unavailable or not allowed' }
                        Write-Audit $action 'before-chart-update' $targetId
                        $allowObserverRecovery = $copiedHash -ceq 'bd2a67d702dfcf248876e9acf52d19761e29ee4ac419604e00b5ece80ce0492f' -or $copiedHash -ceq '543ca18dc190ddc5e12e96b874cb309b029b78f84de544938cde077e93ad2710'
                        $allowRecoveryJs = if ($allowObserverRecovery) { 'true' } else { 'false' }
                        $update=Invoke-Cdp 'Runtime.evaluate' @{expression="(()=>{if(location.protocol!=='https:'||!['jp.tradingview.com','www.tradingview.com'].includes(location.hostname)||(location.port!==''&&location.port!=='443')||!location.pathname.startsWith('/chart/'))throw Error('origin denied');let sources=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent.trim()==='Loop IFD fixed grid (TV1)'&&e.querySelector('[class*=activeStrategy]')&&e.querySelector('[class*=openedInPineEditor]'));if(sources.length===0&&$allowRecoveryJs){const errors=Array.from(document.querySelectorAll('.marker-widget,.markers-panel,.peekview-widget,[role=alert],[data-qa-id=legend-source-item-status]')).some(e=>[e.textContent,e.getAttribute('title')].join(' ').includes('CE10150'));if(errors)sources=Array.from(document.querySelectorAll('[data-qa-id=legend-source-item]')).filter(e=>e.querySelector('[data-qa-id~=legend-source-title]')?.textContent.trim()==='Untitled Script'&&e.querySelector('[class*=activeStrategy]')&&e.querySelector('[class*=openedInPineEditor]'));}if(sources.length!==1||Array.from(document.querySelectorAll('[role=dialog]')).some(e=>e.getClientRects().length))throw Error('owned active TV1 unavailable');const buttons=Array.from(document.querySelectorAll('button[data-qa-id=add-script-to-chart]')).filter(e=>e.getClientRects().length&&e.getAttribute('title')==='更新をチャートに反映');if(buttons.length!==1)throw Error('unique existing-chart update unavailable');for(const type of ['mousedown','mouseup','click'])buttons[0].dispatchEvent(new MouseEvent(type,{bubbles:true}));return {updated:true}})()";returnByValue=$true}
                        if ($update.exceptionDetails) { throw 'fixed runtime chart update failed' }
                        $result.result.value.updated=$true
                    }
                    if ($action -ceq 'bootstrap_add_tv1') {
                        if ($copiedHash -cne 'bd2a67d702dfcf248876e9acf52d19761e29ee4ac419604e00b5ece80ce0492f' -or $normalized.Length -ne 64080) { throw 'add denied: full source not pinned TV1' }
                        if (Test-Path $script:Revoked) { throw 'revoked' }
                        $current = @(Get-Targets | Where-Object { $_.id -ceq $targetId })
                        if ($current.Count -ne 1 -or -not (Test-ChartUrl $current[0].url)) { throw 'target unavailable or not allowed' }
                        Write-Audit $action 'before-add' $targetId
                        $result = Invoke-Cdp 'Runtime.evaluate' @{expression="(()=>{if(location.protocol!=='https:'||!['jp.tradingview.com','www.tradingview.com'].includes(location.hostname)||(location.port!==''&&location.port!=='443')||!location.pathname.startsWith('/chart/'))throw Error('origin denied');const url=new URL(location.href);if(url.searchParams.get('symbol')!=='FX:USDJPY'||url.searchParams.get('interval')!=='5')throw Error('fixed chart query mismatch');if(document.querySelector('[data-qa-id=pine-script-title-button]')?.textContent?.trim()!=='名前なしのスクリプト'||Array.from(document.querySelectorAll('[role=dialog]')).some(e=>e.getClientRects().length))throw Error('owned editor unavailable');const e=document.activeElement;if(!e?.matches('textarea.inputarea')||!e.closest('.monaco-editor.pine-editor-monaco[role=code]'))throw Error('editor focus lost');const intervals=Array.from(document.querySelectorAll('button,[role=button]')).filter(e=>e.getAttribute('aria-label')==='時間足の変更'&&e.getClientRects().length);if(intervals.length!==1||intervals[0].textContent.trim()!=='5')throw Error('rendered interval mismatch');if(!Array.from(document.querySelectorAll('[data-qa-id=legend-titles]')).some(e=>e.textContent.includes('FXCM'))||document.querySelector('[data-qa-id=legend-source-item-status][title=\u0022無効なシンボル\u0022]'))throw Error('rendered provider mismatch');const buttons=Array.from(document.querySelectorAll('[data-qa-id=add-script-to-chart]')).filter(e=>e.getClientRects().length);if(buttons.length!==1)throw Error('unique add script unavailable');for(const type of ['mousedown','mouseup','click'])buttons[0].dispatchEvent(new MouseEvent(type,{bubbles:true}));return {added:true,pinnedSourceVerified:true,compileVerification:'required'}})()";returnByValue=$true}
                        if ($result.exceptionDetails) { throw 'fixed add operation failed' }
                    }
                } finally { if ($null -ne $lastOwnedSequence -and [AgentBrowserClipboardSequence]::GetClipboardSequenceNumber() -eq $lastOwnedSequence) { [Windows.Forms.Clipboard]::SetDataObject($savedClipboard,$true) } }
            }
            Write-Audit $action 'success' $targetId
            @{ok=$true;result=$result.result.value} | ConvertTo-Json -Depth 12 -Compress
        } catch {
            Write-Audit $action 'denied' $targetId
            @{ok=$false;error=$_.Exception.Message} | ConvertTo-Json -Compress
        }
    }
} finally { $script:Socket.Dispose() }
