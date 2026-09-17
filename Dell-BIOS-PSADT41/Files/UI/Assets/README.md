Place approved PNG/JPG logos and banner images here, then set LogoFile and
BannerFile in ../Branding.psd1. Suggested sizes: logo 400x120, banner 1600x320.
Transparent logo backgrounds work well. Empty paths leave company text without an image.
Do not place secrets or executable content here: this folder is readable by users.
Review contrast after changing colors and validate at 100%, 150%, 200% display scale.

The v4 title-bar/taskbar icon is separate from the logo/banner. Choose a local
PNG or ICO in the builder (maximum 1 MB, 1024x1024 pixels). It is decoded for
validation, copied here as app-icon.png/.ico, referenced by IconFile in Branding.psd1,
and included in the runtime SHA256 manifest. Empty IconFile uses the vector device
icon in ../Theme.xaml. A square transparent image with a simple silhouette works
best at 24x24 display units. Rebuild with the matching Intune detection script
after changing branding; never change only the installed cached asset.
