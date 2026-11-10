Public Le0 downloads
====================
Two separate packs (built by Build-PublicPacks.ps1):

1) Le0-Wallet — Start-Le0-Wallet.bat
   Buy / receive / send / hold. Never mines.

2) Le0-Miner — Start-Le0-Miner.bat (or Start-Le0.bat)
   Mines only with a wallet account address + live peers.

Mining rules:
- No wallet address = no mining
- Peers drop = mining pauses
- Old Discord zips stop connecting after a network bump
