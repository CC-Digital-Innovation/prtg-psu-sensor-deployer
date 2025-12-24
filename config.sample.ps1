# PRTG Configuration
# Copy this file to config.ps1 and fill in your credentials
# DO NOT commit config.ps1 to git!

$PrtgConfig = @{
    # Your PRTG username
    Username = "your-prtg-username"

    # Your PRTG password or passhash
    # For better security, use a passhash instead of plain password
    # Get passhash: Invoke-RestMethod "https://prtg.example.com/api/getpasshash.htm?username=USER&password=PASS"
    Password = "your-prtg-password"
}
